import Foundation

enum TallyExcelExporter {
    static func export(rows: [TallyRowDraft]) throws -> URL {
        let exportRows = rows.compactMap(ExportRow.init(row:))
        guard !exportRows.isEmpty else {
            throw ExportError.noRows
        }

        let workbook = XLSXWorkbook(files: [
            XLSXFile(path: "[Content_Types].xml", data: contentTypesXML),
            XLSXFile(path: "_rels/.rels", data: packageRelationshipsXML),
            XLSXFile(path: "docProps/app.xml", data: appPropertiesXML),
            XLSXFile(path: "docProps/core.xml", data: corePropertiesXML),
            XLSXFile(path: "xl/workbook.xml", data: workbookXML),
            XLSXFile(path: "xl/_rels/workbook.xml.rels", data: workbookRelationshipsXML),
            XLSXFile(path: "xl/styles.xml", data: stylesXML),
            XLSXFile(path: "xl/worksheets/sheet1.xml", data: sectionedTallyWorksheetXML(
                rows: exportRows,
                mode: .decimal
            )),
            XLSXFile(path: "xl/worksheets/sheet2.xml", data: sectionedTallyWorksheetXML(
                rows: exportRows,
                mode: .noDecimal
            ))
        ])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipeTallyExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = "Pipe-Tally-\(filenameTimestamp()).xlsx"
        let outputURL = directory.appendingPathComponent(filename)
        try workbook.data().write(to: outputURL, options: .atomic)
        return outputURL
    }
}

private enum ExportError: LocalizedError {
    case noRows

    var errorDescription: String? {
        switch self {
        case .noRows:
            return "There are no rows to export."
        }
    }
}

private struct ExportRow {
    var joint: Int
    var lengthHundredths: Int?
    var status: String

    init?(row: TallyRowDraft) {
        guard let joint = Int(row.jointText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        self.joint = joint
        self.lengthHundredths = TallyLengthFormatter.parseHundredths(from: row.lengthText)
        let warningText = row.warnings.joined(separator: ", ")
        self.status = if lengthHundredths == nil && warningText.isEmpty {
            "Review"
        } else {
            warningText
        }
    }

    var decimalLength: String? {
        guard let lengthHundredths else { return nil }
        return String(format: "%.2f", Double(lengthHundredths) / 100.0)
    }

    var noDecimalLength: String? {
        guard let lengthHundredths else { return nil }
        return "\(lengthHundredths)"
    }
}

private struct XLSXFile {
    var path: String
    var data: Data
}

private enum TallyLengthSheetMode {
    case decimal
    case noDecimal

    var lengthHeader: String {
        switch self {
        case .decimal:
            return "Length 32.00"
        case .noDecimal:
            return "Length 3200"
        }
    }

    var lengthStyle: Int {
        switch self {
        case .decimal:
            return 8
        case .noDecimal:
            return 7
        }
    }

    func lengthValue(for row: ExportRow) -> String? {
        switch self {
        case .decimal:
            return row.decimalLength
        case .noDecimal:
            return row.noDecimalLength
        }
    }

    func runningTotalFormula(lengthColumn: String, rowIndex: Int) -> String {
        let sumRange = "$\(lengthColumn)$3:\(lengthColumn)\(rowIndex)"
        switch self {
        case .decimal:
            return "IF(COUNTA(\(sumRange))=0,&quot;&quot;,SUM(\(sumRange)))"
        case .noDecimal:
            return "IF(COUNTA(\(sumRange))=0,&quot;&quot;,SUM(\(sumRange))/100)"
        }
    }

    func sectionTotalFormula(lengthColumn: String) -> String {
        let sumRange = "$\(lengthColumn)$3:\(lengthColumn)102"
        switch self {
        case .decimal:
            return "IF(COUNTA(\(sumRange))=0,&quot;&quot;,SUM(\(sumRange)))"
        case .noDecimal:
            return "IF(COUNTA(\(sumRange))=0,&quot;&quot;,SUM(\(sumRange))/100)"
        }
    }
}

private struct XLSXWorkbook {
    var files: [XLSXFile]

    func data() -> Data {
        let timestamp = Date()
        var archive = Data()
        var centralDirectory = Data()

        for file in files {
            let localHeaderOffset = UInt32(archive.count)
            let nameData = Data(file.path.utf8)
            let crc = CRC32.checksum(file.data)
            let fileSize = UInt32(file.data.count)
            let dosDateTime = DOSTimestamp(date: timestamp)

            archive.appendUInt32LE(0x0403_4B50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(dosDateTime.time)
            archive.appendUInt16LE(dosDateTime.date)
            archive.appendUInt32LE(crc)
            archive.appendUInt32LE(fileSize)
            archive.appendUInt32LE(fileSize)
            archive.appendUInt16LE(UInt16(nameData.count))
            archive.appendUInt16LE(0)
            archive.append(nameData)
            archive.append(file.data)

            centralDirectory.appendUInt32LE(0x0201_4B50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(dosDateTime.time)
            centralDirectory.appendUInt16LE(dosDateTime.date)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(fileSize)
            centralDirectory.appendUInt32LE(fileSize)
            centralDirectory.appendUInt16LE(UInt16(nameData.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(nameData)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendUInt32LE(0x0605_4B50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(files.count))
        archive.appendUInt16LE(UInt16(files.count))
        archive.appendUInt32LE(UInt32(centralDirectory.count))
        archive.appendUInt32LE(centralDirectoryOffset)
        archive.appendUInt16LE(0)
        return archive
    }
}

private struct DOSTimestamp {
    var date: UInt16
    var time: UInt16

    init(date sourceDate: Date) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: sourceDate
        )
        let year = max((components.year ?? 1980) - 1980, 0)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2

        self.date = UInt16((year << 9) | (month << 5) | day)
        self.time = UInt16((hour << 11) | (minute << 5) | second)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            if value & 1 == 1 {
                value = 0xEDB8_8320 ^ (value >> 1)
            } else {
                value >>= 1
            }
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}

private func sectionedTallyWorksheetXML(rows: [ExportRow], mode: TallyLengthSheetMode) -> Data {
    let minJoint = rows.map(\.joint).min() ?? 1
    let maxJoint = rows.map(\.joint).max() ?? minJoint
    let firstSectionStart = max(((minJoint - 1) / 100) * 100 + 1, 1)
    let lastSectionStart = max(((maxJoint - 1) / 100) * 100 + 1, firstSectionStart)
    let sectionStarts = stride(from: firstSectionStart, through: lastSectionStart, by: 100).map { $0 }
    let lastColumn = excelColumnName((sectionStarts.count - 1) * 4 + 3)

    var rowsByJoint: [Int: ExportRow] = [:]
    for row in rows where rowsByJoint[row.joint] == nil {
        rowsByJoint[row.joint] = row
    }

    var sheetRows = Array(repeating: [String](), count: 103)
    var mergeRefs: [String] = []

    for (sectionIndex, sectionStart) in sectionStarts.enumerated() {
        let startColumnIndex = sectionIndex * 4 + 1
        let jointColumn = excelColumnName(startColumnIndex)
        let lengthColumn = excelColumnName(startColumnIndex + 1)
        let totalColumn = excelColumnName(startColumnIndex + 2)
        let sectionEnd = sectionStart + 99
        let sectionMaxJoint = rows
            .map(\.joint)
            .filter { (sectionStart...sectionEnd).contains($0) }
            .max() ?? sectionStart - 1
        var runningHundredths = 0

        sheetRows[0].append(inlineStringCell("\(jointColumn)1", "Joints \(sectionStart)-\(sectionEnd)", style: 5))
        mergeRefs.append("\(jointColumn)1:\(totalColumn)1")
        sheetRows[1].append(contentsOf: [
            inlineStringCell("\(jointColumn)2", "JT", style: 5),
            inlineStringCell("\(lengthColumn)2", mode.lengthHeader, style: 5),
            inlineStringCell("\(totalColumn)2", "Run Total", style: 5)
        ])

        for rowOffset in 0..<100 {
            let sheetRowIndex = rowOffset + 3
            let joint = sectionStart + rowOffset
            let exportRow = rowsByJoint[joint]

            sheetRows[sheetRowIndex - 1].append(numberCell("\(jointColumn)\(sheetRowIndex)", "\(joint)", style: 6))

            if let exportRow, let length = mode.lengthValue(for: exportRow) {
                sheetRows[sheetRowIndex - 1].append(numberCell(
                    "\(lengthColumn)\(sheetRowIndex)",
                    length,
                    style: mode.lengthStyle
                ))
                runningHundredths += exportRow.lengthHundredths ?? 0
            } else {
                sheetRows[sheetRowIndex - 1].append(blankCell("\(lengthColumn)\(sheetRowIndex)", style: 6))
            }

            if joint <= sectionMaxJoint {
                let formula = mode.runningTotalFormula(lengthColumn: lengthColumn, rowIndex: sheetRowIndex)
                let cachedValue = runningHundredths > 0
                    ? String(format: "%.2f", Double(runningHundredths) / 100.0)
                    : nil
                sheetRows[sheetRowIndex - 1].append(formulaCell(
                    "\(totalColumn)\(sheetRowIndex)",
                    formula,
                    style: 8,
                    cachedValue: cachedValue
                ))
            } else {
                sheetRows[sheetRowIndex - 1].append(blankCell("\(totalColumn)\(sheetRowIndex)", style: 6))
            }
        }

        let totalRowIndex = 103
        let totalFormula = mode.sectionTotalFormula(lengthColumn: lengthColumn)
        let totalCachedValue = runningHundredths > 0
            ? String(format: "%.2f", Double(runningHundredths) / 100.0)
            : nil
        sheetRows[totalRowIndex - 1].append(contentsOf: [
            inlineStringCell("\(jointColumn)\(totalRowIndex)", "Section Total", style: 5),
            blankCell("\(lengthColumn)\(totalRowIndex)", style: 5),
            formulaCell("\(totalColumn)\(totalRowIndex)", totalFormula, style: 8, cachedValue: totalCachedValue)
        ])
    }

    var xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:\(lastColumn)103"/><sheetViews><sheetView workbookViewId="0" showGridLines="0"><pane ySplit="2" topLeftCell="A3" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="B3" sqref="B3"/></sheetView></sheetViews><cols>\(sectionedColumnsXML(sectionCount: sectionStarts.count))</cols><sheetData>
    """

    for (offset, cells) in sheetRows.enumerated() {
        let rowIndex = offset + 1
        let rowHeight: Double? = rowIndex <= 2 ? 22 : nil
        xml += rowXML(index: rowIndex, cells: cells, height: rowHeight)
    }

    let mergeXML = mergeRefs.isEmpty
        ? ""
        : "<mergeCells count=\"\(mergeRefs.count)\">\(mergeRefs.map { "<mergeCell ref=\"\($0)\"/>" }.joined())</mergeCells>"
    xml += "</sheetData>\(mergeXML)</worksheet>"
    return Data(xml.utf8)
}

private func sectionedColumnsXML(sectionCount: Int) -> String {
    (0..<sectionCount).map { sectionIndex in
        let startColumn = sectionIndex * 4 + 1
        return """
        <col min="\(startColumn)" max="\(startColumn)" width="8" customWidth="1"/><col min="\(startColumn + 1)" max="\(startColumn + 1)" width="12" customWidth="1"/><col min="\(startColumn + 2)" max="\(startColumn + 2)" width="13" customWidth="1"/><col min="\(startColumn + 3)" max="\(startColumn + 3)" width="3" customWidth="1"/>
        """
    }.joined()
}

private func excelColumnName(_ oneBasedIndex: Int) -> String {
    var index = oneBasedIndex
    var name = ""

    while index > 0 {
        index -= 1
        let scalar = UnicodeScalar(65 + (index % 26))!
        name.insert(Character(scalar), at: name.startIndex)
        index /= 26
    }

    return name
}

private func rowXML(index: Int, cells: [String], height: Double? = nil) -> String {
    let heightAttributes = height.map { " ht=\"\($0)\" customHeight=\"1\"" } ?? ""
    return "<row r=\"\(index)\"\(heightAttributes)>\(cells.joined())</row>"
}

private func inlineStringCell(_ reference: String, _ value: String, style: Int? = nil) -> String {
    let styleAttribute = style.map { " s=\"\($0)\"" } ?? ""
    return "<c r=\"\(reference)\"\(styleAttribute) t=\"inlineStr\"><is><t>\(xmlEscape(value))</t></is></c>"
}

private func numberCell(_ reference: String, _ value: String, style: Int? = nil) -> String {
    let styleAttribute = style.map { " s=\"\($0)\"" } ?? ""
    return "<c r=\"\(reference)\"\(styleAttribute)><v>\(xmlEscape(value))</v></c>"
}

private func formulaCell(_ reference: String, _ formula: String, style: Int? = nil, cachedValue: String? = nil) -> String {
    let styleAttribute = style.map { " s=\"\($0)\"" } ?? ""
    let valueXML = cachedValue.map { "<v>\(xmlEscape($0))</v>" } ?? ""
    return "<c r=\"\(reference)\"\(styleAttribute)><f>\(formula)</f>\(valueXML)</c>"
}

private func blankCell(_ reference: String, style: Int? = nil) -> String {
    let styleAttribute = style.map { " s=\"\($0)\"" } ?? ""
    return "<c r=\"\(reference)\"\(styleAttribute)/>"
}

private func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func filenameTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

private func exportDisplayTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: Date())
}

private var contentTypesXML: Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
    """.utf8)
}

private var packageRelationshipsXML: Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
    """.utf8)
}

private var workbookXML: Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Decimal Lengths" sheetId="1" r:id="rId1"/><sheet name="No Decimal" sheetId="2" r:id="rId2"/></sheets><calcPr fullCalcOnLoad="1"/></workbook>
    """.utf8)
}

private var workbookRelationshipsXML: Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
    """.utf8)
}

private var stylesXML: Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="0.00"/></numFmts><fonts count="4"><font><sz val="11"/><name val="Aptos"/></font><font><b/><sz val="11"/><name val="Aptos"/></font><font><b/><sz val="14"/><name val="Aptos"/></font><font><i/><sz val="10"/><color rgb="FF666666"/><name val="Aptos"/></font></fonts><fills count="5"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFD9EAF7"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FF7F7F7F"/></left><right style="thin"><color rgb="FF7F7F7F"/></right><top style="thin"><color rgb="FF7F7F7F"/></top><bottom style="thin"><color rgb="FF7F7F7F"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="12"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"><alignment vertical="center"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"><alignment horizontal="right" vertical="center"/></xf><xf numFmtId="1" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"><alignment horizontal="right" vertical="center"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"><alignment horizontal="right" vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1"><alignment horizontal="left" vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"><alignment horizontal="left" vertical="center"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """.utf8)
}

private var corePropertiesXML: Data {
    let created = ISO8601DateFormatter().string(from: Date())
    return Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>PipeTally</dc:creator><cp:lastModifiedBy>PipeTally</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(created)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(created)</dcterms:modified></cp:coreProperties>
    """.utf8)
}

private var appPropertiesXML: Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>PipeTally</Application></Properties>
    """.utf8)
}
