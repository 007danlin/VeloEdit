import Foundation
import CoreFoundation

/// Validate the evidence-bearing JSON constraints before an answer can enter
/// a reusable cache. JSON syntax alone does not validate probability scales.
enum LocalModelResponseValidation {
    static func validate(_ content: String, schema: [String: Any]?) throws {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: Data(content.utf8), options: [.fragmentsAllowed]) }
        catch { throw URLError(.cannotParseResponse) }
        if let schema { try validateValue(value, schema: schema) }
    }

    private static func validateValue(_ value: Any, schema: [String: Any]) throws {
        func require(_ condition: Bool) throws {
            if !condition { throw URLError(.cannotParseResponse) }
        }
        if let alternatives = schema["oneOf"] as? [[String: Any]] {
            let matches = alternatives.filter { alternative in
                (try? validateValue(value, schema: alternative)) != nil
            }
            try require(matches.count == 1)
        }
        if let constant = schema["const"] {
            // NSNumber otherwise equates JSON true with the number 1.
            if let expected = constant as? NSNumber, CFGetTypeID(expected) == CFBooleanGetTypeID() {
                guard let actual = value as? NSNumber, CFGetTypeID(actual) == CFBooleanGetTypeID() else {
                    throw URLError(.cannotParseResponse)
                }
            }
            try require((value as? NSObject)?.isEqual(constant) == true)
        }
        if let choices = schema["enum"] as? [Any] {
            try require(choices.contains { (value as? NSObject)?.isEqual($0) == true })
        }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { throw URLError(.cannotParseResponse) }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            try require((schema["required"] as? [String] ?? []).allSatisfy { object[$0] != nil })
            if schema["additionalProperties"] as? Bool == false {
                try require(Set(object.keys).isSubset(of: Set(properties.keys)))
            }
            for (name, field) in properties {
                if let entry = object[name] { try validateValue(entry, schema: field) }
            }
        case "array":
            guard let array = value as? [Any] else { throw URLError(.cannotParseResponse) }
            if let count = schema["minItems"] as? Int { try require(array.count >= count) }
            if let count = schema["maxItems"] as? Int { try require(array.count <= count) }
            if let items = schema["items"] as? [String: Any] {
                for entry in array { try validateValue(entry, schema: items) }
            }
        case "number", "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw URLError(.cannotParseResponse)
            }
            let numberValue = number.doubleValue
            try require(numberValue.isFinite)
            if schema["type"] as? String == "integer" { try require(numberValue.rounded() == numberValue) }
            if let minimum = schema["minimum"] as? NSNumber { try require(numberValue >= minimum.doubleValue) }
            if let maximum = schema["maximum"] as? NSNumber { try require(numberValue <= maximum.doubleValue) }
        case "boolean":
            guard let number = value as? NSNumber else { throw URLError(.cannotParseResponse) }
            try require(CFGetTypeID(number) == CFBooleanGetTypeID())
        case "string":
            guard let string = value as? String else { throw URLError(.cannotParseResponse) }
            // JSON Schema lengths count Unicode code points, not bytes or
            // Swift grapheme clusters. These constraints apply on cache reads too.
            let count = string.unicodeScalars.count
            if let minimum = schema["minLength"] as? Int { try require(count >= minimum) }
            if let maximum = schema["maxLength"] as? Int { try require(count <= maximum) }
        default: break
        }
    }

    static func repairBody(_ body: [String: Any], additionalInstruction: String = "") -> [String: Any] {
        guard var messages = body["messages"] as? [[String: Any]],
              let index = messages.lastIndex(where: { $0["role"] as? String == "user" }),
              let prompt = messages[index]["content"] as? String else { return body }
        var repaired = body
        // Keep the exact images, their order, model, sampling and output budget.
        // Only the failed observation is repeated, never the completed observers.
        messages[index]["content"] = prompt + "\nFORMAT REPAIR: The previous answer could not be validated. Inspect the same evidence and return only a complete, concise JSON object matching the provided schema, with all required fields and original indices. Scores and confidence must be decimal probabilities from 0.0 to 1.0, never percentages (for example 0.95, not 95). Keep uncertain evidence uncertain; do not change a verdict merely to make it pass validation." + (additionalInstruction.isEmpty ? "" : "\n" + additionalInstruction)
        repaired["messages"] = messages
        return repaired
    }
}
