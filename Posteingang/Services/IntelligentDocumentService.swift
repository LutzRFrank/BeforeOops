import Foundation
import FoundationModels

@Generable
struct GeneratedDocumentAnalysis {
    @Guide(description: "Kurzer deutscher Dokumenttyp, zum Beispiel Reisepass, Rechnung oder Vertrag")
    var documentType: String

    @Guide(description: "Sachliche Zusammenfassung auf Deutsch in höchstens zwei kurzen Sätzen; bei Rechnungen Gesamtbetrag und expliziten Zahlungsstatus nennen")
    var summary: String

    @Guide(description: "Wichtigste sinnvolle nächste Aktion auf Deutsch; keine Aktion, falls nichts erforderlich ist")
    var recommendedAction: String

    @Guide(description: "Exakte wichtigste Datumsangabe aus dem Text oder eine leere Zeichenfolge")
    var actionableDateText: String

    @Guide(description: "Bedeutung dieses Datums, zum Beispiel Ablaufdatum oder Zahlungsfrist; leer wenn kein Datum")
    var actionableDateMeaning: String
}

struct DocumentAnalysisResult: Sendable {
    let documentType: String
    let summary: String
    let recommendedAction: String
    let actionableDateText: String
    let actionableDateMeaning: String
    let usedAppleIntelligence: Bool
}

struct IntelligentDocumentService {
    static let currentAnalysisVersion = 9

    func analyze(title: String, text: String) async -> DocumentAnalysisResult {
        let verifiedDates = DetectedDateService().dates(in: text)
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            return fallbackAnalysis(title: title, text: text)
        }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: """
                Du analysierst private deutsche Dokumente ausschließlich anhand des gelieferten OCR-Texts.
                Erfinde keine Angaben. Unterscheide insbesondere Ausstellungs-, Geburts- und Ablaufdaten.
                Nenne in Zusammenfassung und Handlungsempfehlung keine Datumszahlen.
                Wähle actionableDateText ausschließlich exakt aus der Liste der validierten zukünftigen Datumsangaben.
                Empfehle nur eine Aktion, die aus dem Dokument hervorgeht.
                Bei Rechnungen nenne den Gesamtbetrag und ob sie laut Text bereits bezahlt oder noch offen ist.
                """
            )
            let excerpt = String(text.prefix(12_000))
            let dateOptions = verifiedDates.map(\.sourceText).joined(separator: ", ")
            let response = try await session.respond(
                to: """
                Dokumenttitel: \(title)
                Validierte zukünftige Datumsangaben: \(dateOptions.isEmpty ? "keine" : dateOptions)

                OCR-Text:
                \(excerpt)
                """,
                generating: GeneratedDocumentAnalysis.self,
                options: GenerationOptions(samplingMode: .greedy)
            )
            let result = response.content
            let resolvedDocumentType = canonicalDocumentType(
                modelType: result.documentType,
                title: title,
                text: text
            )
            let groundedDate = verifiedDates.first {
                $0.sourceText == result.actionableDateText
            }?.sourceText
            let resolvedDate = groundedDate ?? preferredDate(
                for: resolvedDocumentType,
                from: verifiedDates,
                in: text
            )?.sourceText ?? ""
            let dateMeaning = resolvedDate.isEmpty
                ? ""
                : stableDateMeaning(for: resolvedDocumentType)
            return DocumentAnalysisResult(
                documentType: resolvedDocumentType,
                summary: stableSummary(
                    for: resolvedDocumentType,
                    modelSummary: result.summary,
                    hasActionableDate: !resolvedDate.isEmpty,
                    text: text
                ),
                recommendedAction: stableAction(
                    for: resolvedDocumentType,
                    hasActionableDate: !resolvedDate.isEmpty,
                    text: text
                ),
                actionableDateText: resolvedDate,
                actionableDateMeaning: dateMeaning,
                usedAppleIntelligence: true
            )
        } catch {
            return fallbackAnalysis(title: title, text: text)
        }
    }

    private func stableAction(for documentType: String, hasActionableDate: Bool, text: String) -> String {
        let normalizedType = documentType.lowercased()
        if hasActionableDate {
            return "Ablauf- oder Fristdatum prüfen und bei Bedarf eine Erinnerung anlegen."
        }
        if normalizedType.contains("rechnung") {
            if invoicePaymentStatus(in: text) == "bereits bezahlt" {
                return "Die bezahlte Rechnung prüfen und anschließend ablegen."
            }
            return "Bezahlstatus prüfen und die Rechnung anschließend ablegen."
        }
        if normalizedType.contains("vertrag") {
            return "Vertragsinhalt und mögliche Fristen prüfen."
        }
        return "Dokument prüfen und anschließend ablegen."
    }

    private func preferredDate(for documentType: String, from dates: [DetectedDate], in text: String) -> DetectedDate? {
        if isIdentityDocument(documentType) { return dates.last }
        let normalized = text.lowercased()
        let deadlineMarkers = [
            " by ", " until ", "deadline", "due date", "return your", "submit",
            " bis ", "frist", "spätestens", "fällig", "zahlbar", "zahlungsziel"
        ]
        return dates.first { detected in
            guard let range = normalized.range(of: detected.sourceText.lowercased()) else { return false }
            let start = normalized.index(range.lowerBound, offsetBy: -80, limitedBy: normalized.startIndex) ?? normalized.startIndex
            let end = normalized.index(range.upperBound, offsetBy: 30, limitedBy: normalized.endIndex) ?? normalized.endIndex
            return deadlineMarkers.contains { normalized[start..<end].contains($0) }
        }
    }

    private func stableDateMeaning(for documentType: String) -> String {
        isIdentityDocument(documentType) ? "Ablaufdatum" : "Fristdatum"
    }

    private func stableSummary(
        for documentType: String,
        modelSummary: String,
        hasActionableDate: Bool,
        text: String
    ) -> String {
        if documentType.lowercased().contains("rechnung") {
            return invoiceFacts(in: text)
                ?? "Rechnung erkannt. Rechnungsbetrag und Bezahlstatus konnten nicht sicher ausgelesen werden."
        }
        guard isIdentityDocument(documentType) else { return modelSummary }
        if hasActionableDate {
            return "\(documentType) erkannt. Das Ablaufdatum wurde aus dem Dokument extrahiert."
        }
        return "\(documentType) erkannt. Es wurde kein zukünftiges Ablaufdatum sicher erkannt."
    }

    private func invoiceFacts(in text: String) -> String? {
        let amount = invoiceTotalAmount(in: text)
        let status = invoicePaymentStatus(in: text)
        guard amount != nil || status != nil else { return nil }
        let amountText = amount.map { "Der Rechnungsbetrag beträgt \($0) €." } ?? ""
        let statusText = status.map { "Die Rechnung ist laut Dokument \($0)." } ?? "Der Bezahlstatus ist nicht eindeutig erkennbar."
        return [amountText, statusText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func invoiceTotalAmount(in text: String) -> String? {
        let labels = [
            "rechnungsbetrag", "gesamtbetrag", "zahlbetrag", "zu zahlen",
            "endbetrag", "bruttobetrag", "grand total", "amount due", "total"
        ]
        let numberPattern = #"(?:\d{1,3}(?:[.\s]\d{3})+|\d{1,6})[.,]\d{2}"#
        let amountPattern = #"(?i)(?:€\s*("# + numberPattern + #")|("# + numberPattern + #")\s*(?:€|eur))"#
        guard let amountExpression = try? NSRegularExpression(pattern: amountPattern) else { return nil }

        func capturedAmount(from match: NSTextCheckingResult, in source: String) -> String? {
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                if let range = Range(match.range(at: group), in: source) {
                    return String(source[range])
                }
            }
            return nil
        }

        // OCR preserves invoice rows more reliably than the visual column order. For an
        // explicitly labelled total, the last monetary value on that row is the final sum,
        // while earlier values can be net amount and VAT from adjacent table columns.
        for line in text.components(separatedBy: .newlines) {
            let normalizedLine = line.lowercased()
                .replacingOccurrences(of: "\t", with: " ")
            guard labels.contains(where: normalizedLine.contains) else { continue }
            let matches = amountExpression.matches(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            )
            if let match = matches.last,
               let amount = capturedAmount(from: match, in: line) {
                return amount
            }
        }

        // Some OCR engines insert a line break between the label and its value. Restrict the
        // fallback to a short window so an unrelated position price cannot win.
        for label in labels {
            guard let labelRange = text.range(of: label, options: [.caseInsensitive]) else { continue }
            let end = text.index(
                labelRange.upperBound,
                offsetBy: 100,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            let window = String(text[labelRange.lowerBound..<end])
            let matches = amountExpression.matches(
                in: window,
                range: NSRange(window.startIndex..., in: window)
            )
            if let match = matches.last,
               let amount = capturedAmount(from: match, in: window) {
                return amount
            }
        }
        return nil
    }

    private func invoicePaymentStatus(in text: String) -> String? {
        let normalized = text.lowercased()
        let paidMarkers = ["wurde per paypal bezahlt", "bereits bezahlt", "ist bezahlt", "zahlung erhalten", "payment received", "paid in full"]
        let openMarkers = ["noch zu zahlen", "offener betrag", "zahlbar bis", "bitte überweisen", "zahlung ausstehend"]
        if paidMarkers.contains(where: normalized.contains) { return "bereits bezahlt" }
        if openMarkers.contains(where: normalized.contains) { return "noch offen" }
        return nil
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func isIdentityDocument(_ documentType: String) -> Bool {
        let normalizedType = documentType.lowercased()
        return normalizedType.contains("personalausweis")
            || normalizedType.contains("reisepass")
            || normalizedType.contains("führerschein")
            || normalizedType.contains("aufenthaltstitel")
    }

    private func canonicalDocumentType(modelType: String, title: String, text: String) -> String {
        let evidence = (title + "\n" + text).lowercased()
        if evidence.contains("personalausweis") || evidence.contains("personal ausweis") {
            return "Personalausweis"
        }
        if evidence.contains("reisepass") || evidence.contains("passport") {
            return "Reisepass"
        }
        if evidence.contains("führerschein") {
            return "Führerschein"
        }
        if evidence.contains("aufenthaltstitel") || evidence.contains("residence permit") {
            return "Aufenthaltstitel"
        }
        if evidence.contains("rechnung") {
            return "Rechnung"
        }
        if evidence.contains("vertrag") {
            return "Vertrag"
        }
        return modelType
    }

    private func fallbackAnalysis(title: String, text: String) -> DocumentAnalysisResult {
        let combined = (title + "\n" + text).lowercased()
        let type: String
        if combined.contains("reisepass") || combined.contains("passport") {
            type = "Reisepass"
        } else if combined.contains("führerschein") {
            type = "Führerschein"
        } else if combined.contains("personalausweis") {
            type = "Personalausweis"
        } else if combined.contains("rechnung") {
            type = "Rechnung"
        } else if combined.contains("vertrag") {
            type = "Vertrag"
        } else {
            type = "Dokument"
        }

        let dates = DetectedDateService().dates(in: text)
        let likelyExpiry = preferredDate(for: type, from: dates, in: text)
        let action: String
        if type == "Rechnung", invoicePaymentStatus(in: text) == "bereits bezahlt" {
            action = "Die bezahlte Rechnung prüfen und anschließend ablegen."
        } else if type == "Rechnung" {
            action = "Bezahlstatus prüfen und die Rechnung anschließend ablegen."
        } else {
            action = likelyExpiry == nil ? "Dokument prüfen" : "Ablaufdatum prüfen und Erinnerung anlegen"
        }
        return DocumentAnalysisResult(
            documentType: type,
            summary: type == "Rechnung"
                ? (invoiceFacts(in: text) ?? "Rechnung wurde lokal erkannt; Betrag und Bezahlstatus konnten nicht sicher bestimmt werden.")
                : "\(type) wurde lokal erkannt und für die weitere Bearbeitung vorbereitet.",
            recommendedAction: action,
            actionableDateText: likelyExpiry?.sourceText ?? "",
            actionableDateMeaning: likelyExpiry == nil ? "" : "Mögliches Ablaufdatum",
            usedAppleIntelligence: false
        )
    }
}
