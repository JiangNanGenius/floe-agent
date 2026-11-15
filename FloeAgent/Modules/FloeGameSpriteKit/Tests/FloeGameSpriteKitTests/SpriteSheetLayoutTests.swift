// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameSpriteCore

@Suite("Sprite-sheet presets and frame grids")
struct SpriteSheetLayoutTests {
    @Test("XP, VX, Ace, MV and MZ presets match actual sheet dimensions")
    func validPresets() throws {
        let xp = try SpriteSheetLayout.applying(.rpgMakerXP, scope: .character,
                                                to: SpritePixelSize(width: 128, height: 128))
        #expect(xp.columns == 4)
        #expect(xp.rows == 4)
        #expect(xp.frameWidth == 32)
        #expect(xp.frameHeight == 32)
        #expect(xp.frameCount == 16)
        try xp.validated(for: SpritePixelSize(width: 128, height: 128))

        for preset in [SpriteSheetPreset.rpgMakerVX, .rpgMakerVXAce, .rpgMakerMV, .rpgMakerMZ] {
            let single = try SpriteSheetLayout.applying(preset, scope: .character,
                                                        to: SpritePixelSize(width: 96, height: 128))
            #expect(single.columns == 3)
            #expect(single.rows == 4)
            #expect(single.frameWidth == 32)
            #expect(single.frameHeight == 32)
            #expect(single.frameCount == 12)

            let full = try SpriteSheetLayout.applying(preset, scope: .fullSheet,
                                                      to: SpritePixelSize(width: 576, height: 384))
            #expect(full.columns == 12)
            #expect(full.rows == 8)
            #expect(full.frameWidth == 48)
            #expect(full.frameHeight == 48)
            #expect(full.frameCount == 96)
        }
    }

    @Test("Preset mismatch is rejected without resizing or cropping")
    func invalidPresets() throws {
        let size = SpritePixelSize(width: 100, height: 90)
        do {
            _ = try SpriteSheetLayout.applying(.rpgMakerMV, scope: .fullSheet, to: size)
            Issue.record("100 × 90 cannot divide into 12 × 8 frames")
        } catch let error as SpriteSheetError {
            guard case .dimensionsMismatch(let width, let height, let columns, let rows) = error else {
                Issue.record("Expected dimensionsMismatch, got \(error)")
                return
            }
            #expect(width == 100)
            #expect(height == 90)
            #expect(columns == 12)
            #expect(rows == 8)
        }

        do {
            _ = try SpriteSheetLayout.applying(.rpgMakerXP, scope: .fullSheet,
                                               to: SpritePixelSize(width: 128, height: 128))
            Issue.record("XP has no separate full-sheet layout")
        } catch let error as SpriteSheetError {
            guard case .presetUnavailable = error else {
                Issue.record("Expected presetUnavailable, got \(error)")
                return
            }
        }

        do {
            _ = try SpriteSheetLayout.custom(for: SpritePixelSize(width: 128, height: 128),
                                             columns: 5, rows: 4)
            Issue.record("128 does not divide into 5 unequal columns")
        } catch let error as SpriteSheetError {
            guard case .dimensionsMismatch = error else {
                Issue.record("Expected dimensionsMismatch, got \(error)")
                return
            }
        }
    }

    @Test("Common sheets auto-detect without forcing an unrelated preset")
    func detection() throws {
        let full = try #require(SpriteSheetLayout.detected(
            for: SpritePixelSize(width: 576, height: 384)))
        #expect(full.preset == .rpgMakerMV)
        #expect(full.scope == .fullSheet)
        #expect(full.columns == 12)
        #expect(full.rows == 8)

        let xp = try #require(SpriteSheetLayout.detected(
            for: SpritePixelSize(width: 128, height: 128)))
        #expect(xp.preset == .rpgMakerXP)
        #expect(xp.frameWidth == 32)

        let single = try #require(SpriteSheetLayout.detected(
            for: SpritePixelSize(width: 96, height: 128)))
        #expect(single.scope == .character)
        #expect(single.columns == 3)
        #expect(single.rows == 4)

        let unknown = SpriteSheetLayout.detected(for: SpritePixelSize(width: 45, height: 20))
        #expect(unknown == nil)
    }

    @Test("Non-square multi-frame crops preserve top-left order and exact pixels")
    func nonSquareCrops() throws {
        let image = try SpriteTestSupport.sheet(columns: 3, rows: 2,
                                                frameWidth: 15, frameHeight: 10)
        let layout = try SpriteSheetLayout.custom(for: image.size, columns: 3, rows: 2)
        #expect(layout.frameWidth == 15)
        #expect(layout.frameHeight == 10)
        #expect(layout.frameCount == 6)

        for index in 0..<layout.frameCount {
            let rect = try #require(layout.frameRect(at: index))
            let cropped = try #require(image.cropped(to: rect))
            #expect(cropped.width == 15)
            #expect(cropped.height == 10)
            let expected = try #require(image.color(x: rect.minX, y: rect.minY))
            var allMatch = true
            for y in 0..<cropped.height {
                for x in 0..<cropped.width where cropped.color(x: x, y: y) != expected {
                    allMatch = false
                    break
                }
                if !allMatch { break }
            }
            #expect(allMatch)
            #expect(cropped.color(x: 0, y: 0) == expected)
            #expect(cropped.color(x: 14, y: 9) == expected)
        }

        let topRight = try #require(layout.frameRect(at: 2))
        #expect(topRight.x == 30)
        #expect(topRight.y == 0)
        let bottomLeft = try #require(layout.frameRect(at: 3))
        #expect(bottomLeft.x == 0)
        #expect(bottomLeft.y == 10)
        let topRightColor = try #require(image.color(x: 30, y: 0))
        let bottomLeftColor = try #require(image.color(x: 0, y: 10))
        #expect(topRightColor != bottomLeftColor)
    }

    @Test("Frame groups stay inside each character block")
    func groupsAndAnimation() throws {
        let full = try SpriteSheetLayout.applying(.rpgMakerMV, scope: .fullSheet,
                                                  to: SpritePixelSize(width: 576, height: 384))
        let groups = full.frameGroups()
        #expect(groups.count == 8)
        #expect(groups.allSatisfy { $0.frameIndices.count == 12 })
        // A 12-column sheet is row-major. Each 3x4 character therefore
        // occupies three cells on each of four separate sheet rows.
        #expect(groups[0].frameIndices == [0, 1, 2, 12, 13, 14, 24, 25, 26, 36, 37, 38])
        #expect(groups[1].frameIndices.first == 3)
        for (character, group) in groups.enumerated() {
            #expect(group.frameIndices.allSatisfy { full.descriptor(at: $0)?.characterIndex == character })
        }
        #expect(Set(groups.flatMap(\.frameIndices)) == Set(0..<96))

        let frameFive = try #require(full.descriptor(at: 5))
        #expect(frameFive.characterIndex == 1)
        #expect(frameFive.localColumn == 2)
        #expect(frameFive.direction == .down)
        #expect(full.animationFrameIndices(containing: 5) == [3, 4, 5])

        let frameThirteen = try #require(full.descriptor(at: 13))
        #expect(frameThirteen.direction == .left)
        #expect(full.animationFrameIndices(containing: 13) == [12, 13, 14])

        let xp = try SpriteSheetLayout.applying(.rpgMakerXP, scope: .character,
                                                to: SpritePixelSize(width: 128, height: 128))
        #expect(xp.frameGroups().count == 1)
        #expect(xp.animationFrameIndices(containing: 5) == [4, 5, 6, 7])

        let custom = try SpriteSheetLayout.custom(for: SpritePixelSize(width: 30, height: 10),
                                                  columns: 3, rows: 1)
        #expect(custom.frameGroups().count == 1)
        #expect(custom.animationFrameIndices(containing: 1) == [0, 1, 2])
    }

    @Test("Rotation keeps an exactly-covering transposed grid")
    func transposedGrid() throws {
        let full = try SpriteSheetLayout.applying(.rpgMakerMV, scope: .fullSheet,
                                                  to: SpritePixelSize(width: 576, height: 384))
        let rotated = try #require(full.transposedForRotation())
        #expect(rotated.columns == 8)
        #expect(rotated.rows == 12)
        #expect(rotated.frameWidth == 48)
        #expect(rotated.frameHeight == 48)
        try rotated.validated(for: SpritePixelSize(width: 384, height: 576))
    }
}
