import Foundation

/// JSON object order can determine the constrained decoder's generation order.
/// Keep the selected observation order in both the receipt and the wire bytes;
/// all values, constraints and other object ordering remain unchanged.
enum LocalAIRequestEncoding {
    static func data(_ body: [String: Any], responseFieldOrder: [String]? = nil,
                     responseArrayItemFieldOrders: [String: [String]] = [:]) throws -> Data {
        guard responseFieldOrder != nil || !responseArrayItemFieldOrders.isEmpty else {
            return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        guard let format = body["format"] as? [String: Any],
              let properties = format["properties"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let order = responseFieldOrder ?? properties.keys.sorted()
        guard order.count == properties.count, Set(order) == Set(properties.keys) else { throw URLError(.cannotParseResponse) }
        var arrays: [String: Data] = [:]
        for (key, itemOrder) in responseArrayItemFieldOrders {
            guard let array = properties[key] as? [String: Any], array["type"] as? String == "array",
                  let item = array["items"] as? [String: Any],
                  let fields = item["properties"] as? [String: Any],
                  itemOrder.count == fields.count, Set(itemOrder) == Set(fields.keys) else { throw URLError(.cannotParseResponse) }
            let orderedItem = try object(item, replacing: ["properties": object(fields, keys: itemOrder)])
            arrays[key] = try object(array, replacing: ["items": orderedItem])
        }
        let orderedProperties = try object(properties, keys: order, replacing: arrays)
        let orderedFormat = try object(format, replacing: ["properties": orderedProperties])
        return try object(body, replacing: ["format": orderedFormat])
    }

    private static func object(_ value: [String: Any], keys: [String]? = nil,
                               replacing: [String: Data] = [:]) throws -> Data {
        var data = Data("{".utf8)
        for (index, key) in (keys ?? value.keys.sorted()).enumerated() {
            if index > 0 { data.append(44) }
            data.append(try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]))
            data.append(58)
            if let replacement = replacing[key] { data.append(replacement) }
            else {
                data.append(try JSONSerialization.data(withJSONObject: value[key]!,
                    options: [.fragmentsAllowed, .sortedKeys]))
            }
        }
        data.append(125)
        return data
    }
}
