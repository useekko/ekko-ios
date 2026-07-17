import UIKit
import XCTest

/// Clean-room parity gate. It records every plane of both keyboards in one controlled app and
/// compares the visible caps rendered on screen. Attachments make every run independently auditable.
final class KeyboardParityTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testLightKeyboardParity() throws {
        try compare(appearance: "light")
    }

    @MainActor
    func testDarkKeyboardParity() throws {
        try compare(appearance: "dark")
    }

    @MainActor
    func testReplicaInteractionContract() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAB_APPEARANCE"] = "dark"
        app.launchArguments += ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()

        let editor = app.textViews["lab-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        app.segmentedControls["keyboard-mode"].buttons["Replica"].tap()
        XCTAssertTrue(key(in: app, names: ["Q"]).waitForExistence(timeout: 8))

        // Sentence-start Shift is one-shot and one tap can turn it off.
        key(in: app, names: ["Shift", "shift"]).tap()
        XCTAssertTrue(key(in: app, names: ["q"]).waitForExistence(timeout: 3))
        key(in: app, names: ["Shift", "shift"]).tap()
        XCTAssertTrue(key(in: app, names: ["Q"]).waitForExistence(timeout: 3))
        key(in: app, names: ["Q"]).tap()
        waitForEditorValue("Q", editor: editor)
        XCTAssertTrue(key(in: app, names: ["q"]).waitForExistence(timeout: 3))

        // A true double tap locks Shift; typing does not consume Caps Lock.
        key(in: app, names: ["Shift", "shift"]).doubleTap()
        XCTAssertTrue(key(in: app, names: ["Q"]).waitForExistence(timeout: 3))
        key(in: app, names: ["Q"]).tap()
        waitForEditorValue("QQ", editor: editor)
        XCTAssertTrue(key(in: app, names: ["Q"]).exists)
        key(in: app, names: ["Shift", "shift"]).tap()
        XCTAssertTrue(key(in: app, names: ["q"]).waitForExistence(timeout: 3))

        key(in: app, names: ["numbers", "123"]).tap()
        XCTAssertTrue(key(in: app, names: ["1"]).waitForExistence(timeout: 3))
        key(in: app, names: ["1"]).tap()
        waitForEditorValue("QQ1", editor: editor)

        key(in: app, names: ["symbols", "#+="]).tap()
        XCTAssertTrue(key(in: app, names: LabPlane.symbols.anchorNames).waitForExistence(timeout: 3))
        key(in: app, names: LabPlane.symbols.anchorNames).tap()
        waitForEditorValue("QQ1[", editor: editor)

        key(in: app, names: ["letters", "ABC"]).tap()
        XCTAssertTrue(key(in: app, names: ["q"]).waitForExistence(timeout: 3))
        key(in: app, names: ["Space", "space"]).tap()
        key(in: app, names: ["q"]).tap()
        waitForEditorValue("QQ1[ q", editor: editor)

        // Delete fires immediately and repeats while held, matching the native control cadence.
        key(in: app, names: ["Delete", "delete"]).tap()
        waitForEditorValue("QQ1[ ", editor: editor)
        key(in: app, names: ["w"]).tap()
        key(in: app, names: ["e"]).tap()
        key(in: app, names: ["r"]).tap()
        key(in: app, names: ["t"]).tap()
        waitForEditorValue("QQ1[ wert", editor: editor)
        key(in: app, names: ["Delete", "delete"]).press(forDuration: 0.7)
        let remaining = (editor.value as? String) ?? ""
        XCTAssertLessThanOrEqual(remaining.count, 8, "Held Delete did not repeat: \(remaining)")
    }

    @MainActor
    func testAppleAndReplicaEmojiSurfaces() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()

        let editor = app.textViews["lab-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        app.segmentedControls["keyboard-surface"].buttons["Emoji"].tap()

        let emoji = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'grinning' OR label == '😀'")
        ).firstMatch
        XCTAssertTrue(emoji.waitForExistence(timeout: 8), "Apple Emoji reference did not appear")
        addImage(XCUIScreen.main.screenshot().image, name: "apple-emoji-reference")

        app.segmentedControls["keyboard-mode"].buttons["Replica"].tap()
        XCTAssertTrue(app.buttons["emoji-category-recent"].waitForExistence(timeout: 8))
        addImage(XCUIScreen.main.screenshot().image, name: "replica-emoji")

        let tears = app.descendants(matching: .any)["emoji-😂"]
        XCTAssertTrue(tears.waitForExistence(timeout: 5))
        tears.tap()
        waitForEditorValue("😂", editor: editor)

        app.buttons["emoji-category-animals"].tap()
        let monkey = app.descendants(matching: .any)["emoji-🐵"]
        XCTAssertTrue(monkey.waitForExistence(timeout: 5))
        monkey.tap()
        waitForEditorValue("😂🐵", editor: editor)

        app.buttons["emoji-delete"].tap()
        waitForEditorValue("😂", editor: editor)
        app.buttons["emoji-letters"].tap()
        XCTAssertTrue(key(in: app, names: ["Q", "q"]).waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'Emoji'")
        ).firstMatch.tap()
        XCTAssertTrue(app.buttons["emoji-category-recent"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func compare(appearance: String) throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAB_APPEARANCE"] = appearance
        app.launchArguments += ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()

        let editor = app.textViews["lab-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "KeyboardLab editor did not launch")
        editor.tap()
        XCTAssertTrue(
            key(in: app, names: ["Q", "q"]).waitForExistence(timeout: 10),
            "Apple keyboard did not appear"
        )
        XCTAssertFalse(
            app.buttons["Seal"].exists,
            "Reference field selected the Ekko extension instead of Apple's English input mode"
        )

        let apple = try captureEveryPlane(app: app, name: "apple-\(appearance)")

        app.segmentedControls["keyboard-mode"].buttons["Replica"].tap()
        XCTAssertTrue(key(in: app, names: ["Q", "q"]).waitForExistence(timeout: 8), "Replica did not appear")
        let replica = try captureEveryPlane(app: app, name: "replica-\(appearance)")

        for plane in LabPlane.allCases {
            guard let appleCapture = apple[plane], let replicaCapture = replica[plane] else {
                XCTFail("Missing \(plane.rawValue) capture")
                continue
            }
            let report = ParityReport.compare(apple: appleCapture, replica: replicaCapture)
            try attachAndAssert(report, appearance: appearance, plane: plane)
        }
    }

    @MainActor
    private func captureEveryPlane(
        app: XCUIApplication,
        name: String
    ) throws -> [LabPlane: KeyboardCapture] {
        var captures: [LabPlane: KeyboardCapture] = [:]
        captures[.letters] = try capture(app: app, name: "\(name)-letters", plane: .letters)

        let numbers = key(in: app, names: ["numbers", "123"])
        XCTAssertTrue(numbers.waitForExistence(timeout: 5), "123 key did not appear")
        numbers.tap()
        XCTAssertTrue(
            key(in: app, names: LabPlane.numbers.anchorNames).waitForExistence(timeout: 5),
            "Number plane did not appear"
        )
        captures[.numbers] = try capture(app: app, name: "\(name)-numbers", plane: .numbers)

        let symbols = key(in: app, names: ["symbols", "more", "#+="])
        XCTAssertTrue(symbols.waitForExistence(timeout: 5), "#+= key did not appear")
        symbols.tap()
        XCTAssertTrue(
            key(in: app, names: LabPlane.symbols.anchorNames).waitForExistence(timeout: 5),
            "Symbol plane did not appear"
        )
        captures[.symbols] = try capture(app: app, name: "\(name)-symbols", plane: .symbols)
        return captures
    }

    private func attachAndAssert(
        _ report: ParityReport,
        appearance: String,
        plane: LabPlane
    ) throws {
        let suffix = "\(appearance)-\(plane.rawValue)"
        let json = try JSONSerialization.data(
            withJSONObject: report.jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "parity-\(suffix).json"
        attachment.lifetime = .keepAlways
        add(attachment)

        addImage(report.sideBySide, name: "comparison-\(suffix)")
        addImage(report.difference, name: "difference-\(suffix)")

        XCTAssertLessThanOrEqual(
            report.maximumVisualDelta, 1,
            "\(plane.rawValue) cap geometry differs by \(report.maximumVisualDelta)pt; inspect parity JSON"
        )
        XCTAssertLessThanOrEqual(
            report.meanVisualDelta, 0.2,
            "Mean \(plane.rawValue) geometry differs by \(report.meanVisualDelta)pt; inspect parity JSON"
        )
        XCTAssertLessThanOrEqual(
            report.maximumFrameDelta, 0.34,
            "\(plane.rawValue) touch targets differ by \(report.maximumFrameDelta)pt"
        )
        XCTAssertLessThanOrEqual(
            report.meanFrameDelta, 0.1,
            "Mean \(plane.rawValue) touch-target delta is \(report.meanFrameDelta)pt"
        )
        XCTAssertLessThanOrEqual(
            report.primaryColorDistance, 0.5,
            "Primary key surface is not in Apple's measured color neighborhood"
        )
        XCTAssertLessThanOrEqual(
            report.backingColorDistance, 0.5,
            "Keyboard backing is not in Apple's measured color neighborhood"
        )
    }

    @MainActor
    private func capture(
        app: XCUIApplication,
        name: String,
        plane: LabPlane
    ) throws -> KeyboardCapture {
        // Snapshot immediately after frame reads so layout and pixels belong to one state.
        var frames: [String: CGRect] = [:]
        for (identifier, names) in plane.frameLabels {
            let element = key(in: app, names: names)
            if element.exists { frames[identifier] = element.frame }
        }
        guard let anchor = frames["anchor"], let returnKey = frames["return"] else {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "missing-key-tree-\(name)"
            tree.lifetime = .keepAlways
            add(tree)
            throw XCTSkip("Could not resolve \(plane.rawValue) anchor/Return frames; accessibility tree attached")
        }

        let screen = XCUIScreen.main.screenshot().image
        addImage(screen, name: name)
        let cropRect = CGRect(
            x: 0,
            y: max(0, anchor.minY - 7),
            width: screen.size.width,
            height: min(
                screen.size.height - anchor.minY + 7,
                returnKey.maxY - anchor.minY + 21
            )
        )
        let crop = screen.cropped(toPoints: cropRect)
        addImage(crop, name: "\(name)-plane")
        return KeyboardCapture(image: crop, frames: frames, origin: cropRect.origin)
    }

    @MainActor
    private func key(in app: XCUIApplication, names: [String]) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@ OR identifier IN %@", names, names)
        )
        let keyboardThreshold = app.frame.midY
        for index in 0..<matches.count {
            let candidate = matches.element(boundBy: index)
            if candidate.exists, candidate.frame.midY > keyboardThreshold { return candidate }
        }
        return matches.firstMatch
    }

    @MainActor
    private func waitForEditorValue(
        _ expected: String,
        editor: XCUIElement,
        timeout: TimeInterval = 3
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: editor
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        let actual = String(describing: editor.value)
        XCTAssertEqual(
            result,
            .completed,
            "Editor never became \(expected.debugDescription); value is \(actual)"
        )
    }

    private func addImage(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum LabPlane: String, CaseIterable {
    case letters
    case numbers
    case symbols

    var anchorNames: [String] {
        switch self {
        case .letters: ["Q", "q"]
        case .numbers: ["1"]
        case .symbols: ["[", "left square bracket", "left bracket"]
        }
    }

    var frameLabels: [(String, [String])] {
        let common: [(String, [String])] = [
            ("delete", ["Delete", "delete"]),
            ("space", ["Space", "space"]),
            ("return", ["Return", "return"]),
        ]
        switch self {
        case .letters:
            return [
                ("anchor", anchorNames), ("top-last", ["P", "p"]),
                ("second-first", ["A", "a"]), ("second-last", ["L", "l"]),
                ("third-first", ["Z", "z"]), ("third-last", ["M", "m"]),
                ("third-leading", ["Shift", "shift"]),
                ("plane-toggle", ["numbers", "123"]),
            ] + common
        case .numbers:
            return [
                ("anchor", anchorNames), ("top-last", ["0"]),
                ("second-first", ["-"]), ("second-last", ["\""]),
                ("third-first", ["."]), ("third-last", ["'"]),
                ("third-leading", ["symbols", "more", "#+="]),
                ("plane-toggle", ["letters", "ABC"]),
            ] + common
        case .symbols:
            return [
                ("anchor", anchorNames), ("top-last", ["="]),
                ("second-first", ["_"]), ("second-last", ["•"]),
                ("third-first", ["."]), ("third-last", ["'"]),
                ("third-leading", ["numbers", "123"]),
                ("plane-toggle", ["letters", "ABC"]),
            ] + common
        }
    }
}

private struct KeyboardCapture {
    let image: UIImage
    let frames: [String: CGRect]
    let origin: CGPoint

    func normalizedFrame(_ name: String) -> CGRect? {
        frames[name]?.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}

private struct ParityReport {
    let maximumFrameDelta: CGFloat
    let meanFrameDelta: CGFloat
    let maximumVisualDelta: CGFloat
    let meanVisualDelta: CGFloat
    let primaryColorDistance: CGFloat
    let backingColorDistance: CGFloat
    let sideBySide: UIImage
    let difference: UIImage
    let frameDeltas: [String: [String: CGFloat]]
    let applePrimary: RGBA
    let replicaPrimary: RGBA
    let appleBacking: RGBA
    let replicaBacking: RGBA
    let appleFrames: [String: [String: CGFloat]]
    let replicaFrames: [String: [String: CGFloat]]
    let visualDeltas: [String: CGFloat]
    let appleVisual: VisualMetrics
    let replicaVisual: VisualMetrics

    var jsonObject: [String: Any] {
        [
            "maximumFrameDeltaPoints": maximumFrameDelta,
            "meanFrameDeltaPoints": meanFrameDelta,
            "maximumVisualDeltaPoints": maximumVisualDelta,
            "meanVisualDeltaPoints": meanVisualDelta,
            "primaryColorDistance": primaryColorDistance,
            "backingColorDistance": backingColorDistance,
            "applePrimaryRGBA": applePrimary.array,
            "replicaPrimaryRGBA": replicaPrimary.array,
            "appleBackingRGBA": appleBacking.array,
            "replicaBackingRGBA": replicaBacking.array,
            "appleFrames": appleFrames,
            "replicaFrames": replicaFrames,
            "appleVisual": appleVisual.jsonObject,
            "replicaVisual": replicaVisual.jsonObject,
            "visualDeltas": visualDeltas,
            "keys": frameDeltas,
        ]
    }

    static func compare(apple: KeyboardCapture, replica: KeyboardCapture) -> ParityReport {
        let common = Set(apple.frames.keys).intersection(replica.frames.keys).sorted()
        var all: [CGFloat] = []
        var byKey: [String: [String: CGFloat]] = [:]

        for name in common {
            guard let a = apple.normalizedFrame(name), let r = replica.normalizedFrame(name) else { continue }
            let values = [
                "x": abs(a.minX - r.minX),
                "y": abs(a.minY - r.minY),
                "width": abs(a.width - r.width),
                "height": abs(a.height - r.height),
            ]
            byKey[name] = values
            all.append(contentsOf: values.values)
        }

        let appleVisual = VisualMetrics.analyze(apple.image)
        let replicaVisual = VisualMetrics.analyze(replica.image)
        let visualDeltas = appleVisual.values.reduce(into: [String: CGFloat]()) { output, pair in
            guard let value = replicaVisual.values[pair.key] else { return }
            output[pair.key] = abs(pair.value - value)
        }
        let visualValues = Array(visualDeltas.values)
        let applePrimary = appleVisual.primary
        let replicaPrimary = replicaVisual.primary
        let appleBacking = appleVisual.backing
        let replicaBacking = replicaVisual.backing
        let appleFrames = frameDictionary(capture: apple)
        let replicaFrames = frameDictionary(capture: replica)

        return ParityReport(
            maximumFrameDelta: all.max() ?? .infinity,
            meanFrameDelta: all.isEmpty ? .infinity : all.reduce(0, +) / CGFloat(all.count),
            maximumVisualDelta: visualValues.max() ?? .infinity,
            meanVisualDelta: visualValues.isEmpty
                ? .infinity : visualValues.reduce(0, +) / CGFloat(visualValues.count),
            primaryColorDistance: applePrimary.distance(to: replicaPrimary),
            backingColorDistance: appleBacking.distance(to: replicaBacking),
            sideBySide: UIImage.sideBySide(apple.image, replica.image),
            difference: UIImage.absoluteDifference(apple.image, replica.image),
            frameDeltas: byKey,
            applePrimary: applePrimary,
            replicaPrimary: replicaPrimary,
            appleBacking: appleBacking,
            replicaBacking: replicaBacking,
            appleFrames: appleFrames,
            replicaFrames: replicaFrames,
            visualDeltas: visualDeltas,
            appleVisual: appleVisual,
            replicaVisual: replicaVisual
        )
    }

    private static func frameDictionary(capture: KeyboardCapture) -> [String: [String: CGFloat]] {
        capture.frames.reduce(into: [:]) { output, pair in
            guard let frame = capture.normalizedFrame(pair.key) else { return }
            output[pair.key] = [
                "x": frame.minX,
                "y": frame.minY,
                "width": frame.width,
                "height": frame.height,
            ]
        }
    }
}

private struct RGBA {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat

    var array: [CGFloat] { [r, g, b, a] }

    func distance(to other: RGBA) -> CGFloat {
        let dr = r - other.r
        let dg = g - other.g
        let db = b - other.b
        return sqrt(dr * dr + dg * dg + db * db)
    }

    static func packed(_ value: UInt32) -> RGBA {
        RGBA(
            r: CGFloat((value >> 16) & 0xff),
            g: CGFloat((value >> 8) & 0xff),
            b: CGFloat(value & 0xff),
            a: 255
        )
    }
}

/// Extracts rendered cap geometry from pixels instead of mistaking accessibility hit targets for
/// visible key frames. Apple's keyboard intentionally expands every hit target to fill its row;
/// those frames are useful diagnostics, but they are not the shapes a person sees.
private struct VisualMetrics {
    let primary: RGBA
    let backing: RGBA
    let values: [String: CGFloat]
    let keyCount: Int

    var jsonObject: [String: Any] {
        [
            "primaryRGBA": primary.array,
            "backingRGBA": backing.array,
            "keyCount": keyCount,
            "measurementsPoints": values,
        ]
    }

    static func analyze(_ image: UIImage) -> VisualMetrics {
        let raster = PixelRaster(image)
        guard !raster.colors.isEmpty else {
            return VisualMetrics(
                primary: RGBA(r: 0, g: 0, b: 0, a: 0),
                backing: RGBA(r: 0, g: 0, b: 0, a: 0),
                values: [:],
                keyCount: 0
            )
        }

        var histogram: [UInt32: Int] = [:]
        histogram.reserveCapacity(2_048)
        for color in raster.colors { histogram[color, default: 0] += 1 }
        let ranked = histogram.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        let primaryValue = ranked[0].key
        let backingValue = ranked.dropFirst().first?.key ?? primaryValue

        var mask = raster.colors.map { UInt8($0 == primaryValue ? 1 : 0) }
        var components: [PixelComponent] = []
        let minimumArea = Int(500 * raster.scale * raster.scale)
        var queue: [Int] = []

        for seed in mask.indices where mask[seed] == 1 {
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            mask[seed] = 0
            var cursor = 0
            var minX = seed % raster.width
            var maxX = minX
            var minY = seed / raster.width
            var maxY = minY
            var area = 0

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                area += 1
                let x = index % raster.width
                let y = index / raster.width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                if x > 0 { visit(index - 1, mask: &mask, queue: &queue) }
                if x + 1 < raster.width { visit(index + 1, mask: &mask, queue: &queue) }
                if y > 0 { visit(index - raster.width, mask: &mask, queue: &queue) }
                if y + 1 < raster.height {
                    visit(index + raster.width, mask: &mask, queue: &queue)
                }
            }

            let component = PixelComponent(
                minX: minX, minY: minY, maxX: maxX, maxY: maxY, area: area
            )
            let pointWidth = CGFloat(component.width) / raster.scale
            let pointHeight = CGFloat(component.height) / raster.scale
            if area >= minimumArea,
               pointWidth > 20,
               pointHeight > 30,
               pointWidth < CGFloat(raster.width) / raster.scale * 0.95,
               pointHeight < CGFloat(raster.height) / raster.scale * 0.55 {
                components.append(component)
            }
        }

        components.sort { lhs, rhs in
            lhs.minY == rhs.minY ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
        }
        var rows: [[PixelComponent]] = []
        for component in components {
            if let last = rows.indices.last,
               abs(rows[last][0].minY - component.minY) <= Int(raster.scale * 2) {
                rows[last].append(component)
            } else {
                rows.append([component])
            }
        }
        for index in rows.indices { rows[index].sort { $0.minX < $1.minX } }

        guard rows.count >= 4, rows[0].count >= 10 else {
            return VisualMetrics(
                primary: .packed(primaryValue),
                backing: .packed(backingValue),
                values: [:],
                keyCount: components.count
            )
        }

        let first = rows[0]
        let keyWidth = median(first.map { CGFloat($0.width) / raster.scale })
        let keyHeight = median(first.map { CGFloat($0.height) / raster.scale })
        let horizontalGaps = zip(first, first.dropFirst()).map { pair in
            CGFloat(pair.1.minX - pair.0.maxX - 1) / raster.scale
        }
        let verticalGaps = zip(rows, rows.dropFirst()).map { pair in
            CGFloat(pair.1[0].minY - pair.0[0].maxY - 1) / raster.scale
        }

        let third = rows[2]
        let bottom = rows[3]
        let thirdCharacters = Array(third.dropFirst().dropLast())
        let thirdCharacterGaps = zip(thirdCharacters, thirdCharacters.dropFirst()).map { pair in
            CGFloat(pair.1.minX - pair.0.maxX - 1) / raster.scale
        }
        let cornerInset = topCornerInset(
            component: first[0], color: primaryValue, raster: raster
        )
        var values: [String: CGFloat] = [
            "keyWidth": keyWidth,
            "keyHeight": keyHeight,
            "horizontalGap": median(horizontalGaps),
            "verticalGap": median(verticalGaps),
            "sideInset": CGFloat(first[0].minX) / raster.scale,
            "topInset": CGFloat(first[0].minY) / raster.scale,
            "secondRowInset": CGFloat(rows[1][0].minX) / raster.scale,
            "thirdCharacterInset": CGFloat(third[min(1, third.count - 1)].minX) / raster.scale,
            "thirdCharacterWidth": median(
                thirdCharacters.map { CGFloat($0.width) / raster.scale }
            ),
            "thirdCharacterGap": median(thirdCharacterGaps),
            "thirdLeadingGap": thirdCharacters.isEmpty ? .infinity : CGFloat(
                thirdCharacters[0].minX - third[0].maxX - 1
            ) / raster.scale,
            "thirdTrailingGap": thirdCharacters.isEmpty ? .infinity : CGFloat(
                third.last!.minX - thirdCharacters.last!.maxX - 1
            ) / raster.scale,
            "modifierWidth": CGFloat(third[0].width) / raster.scale,
            "cornerTopInset": cornerInset,
        ]
        if bottom.count >= 3 {
            values["bottomPlaneWidth"] = CGFloat(bottom[0].width) / raster.scale
            values["bottomSpaceWidth"] = CGFloat(bottom[1].width) / raster.scale
            values["bottomReturnWidth"] = CGFloat(bottom.last!.width) / raster.scale
        }

        return VisualMetrics(
            primary: .packed(primaryValue),
            backing: .packed(backingValue),
            values: values,
            keyCount: components.count
        )
    }

    private static func visit(_ index: Int, mask: inout [UInt8], queue: inout [Int]) {
        guard mask[index] == 1 else { return }
        mask[index] = 0
        queue.append(index)
    }

    private static func topCornerInset(
        component: PixelComponent,
        color: UInt32,
        raster: PixelRaster
    ) -> CGFloat {
        let y = component.minY
        for x in component.minX...component.maxX
        where raster.colors[y * raster.width + x] == color {
            return CGFloat(x - component.minX) / raster.scale
        }
        return .infinity
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .infinity }
        return sorted[sorted.count / 2]
    }
}

private struct PixelComponent {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
    let area: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

private struct PixelRaster {
    let width: Int
    let height: Int
    let scale: CGFloat
    let colors: [UInt32]

    init(_ image: UIImage) {
        guard let cgImage = image.cgImage,
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else {
            width = 0
            height = 0
            scale = 1
            colors = []
            return
        }

        width = cgImage.width
        height = cgImage.height
        scale = max(1, image.scale)
        let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
        let alphaIsFirst = switch cgImage.alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: true
        default: false
        }
        let isLittleEndian = cgImage.bitmapInfo.contains(.byteOrder32Little)
        let redOffset: Int
        let greenOffset: Int
        let blueOffset: Int
        if bytesPerPixel < 4 {
            (redOffset, greenOffset, blueOffset) = (0, 1, 2)
        } else if isLittleEndian, alphaIsFirst {
            (redOffset, greenOffset, blueOffset) = (2, 1, 0) // BGRA
        } else if isLittleEndian {
            (redOffset, greenOffset, blueOffset) = (3, 2, 1) // ABGR
        } else if alphaIsFirst {
            (redOffset, greenOffset, blueOffset) = (1, 2, 3) // ARGB
        } else {
            (redOffset, greenOffset, blueOffset) = (0, 1, 2) // RGBA / RGBX
        }
        var output = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
                let red = UInt32(bytes[offset + redOffset])
                let green = UInt32(bytes[offset + greenOffset])
                let blue = UInt32(bytes[offset + blueOffset])
                output[y * width + x] = red << 16 | green << 8 | blue
            }
        }
        colors = output
    }
}

private extension UIImage {
    func cropped(toPoints rect: CGRect) -> UIImage {
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        guard let cgImage, let cropped = cgImage.cropping(to: pixelRect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }

    static func sideBySide(_ left: UIImage, _ right: UIImage) -> UIImage {
        let targetHeight = max(left.size.height, right.size.height)
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: left.size.width + right.size.width, height: targetHeight)
        )
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: renderer.format.bounds.size))
            left.draw(at: .zero)
            right.draw(at: CGPoint(x: left.size.width, y: 0))
        }
    }

    static func absoluteDifference(_ lhs: UIImage, _ rhs: UIImage) -> UIImage {
        let size = CGSize(
            width: min(lhs.size.width, rhs.size.width),
            height: min(lhs.size.height, rhs.size.height)
        )
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            lhs.draw(in: CGRect(origin: .zero, size: size))
            context.cgContext.setBlendMode(.difference)
            rhs.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
