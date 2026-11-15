// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameWebKit

@Test func keyboardDescriptorsCoverEverySerializableKey() throws {
    #expect(Set(GameKeyboardKey.allCases.map { $0.descriptor.code }).count == GameKeyboardKey.allCases.count)
    for key in GameKeyboardKey.allCases {
        #expect(!key.descriptor.key.isEmpty)
        #expect((1...255).contains(key.descriptor.keyCode))
        #expect((0...3).contains(key.descriptor.location))
        #expect(key.x11KeySym > 0)
        #expect(try JSONDecoder().decode(GameKeyboardKey.self, from: JSONEncoder().encode(key)) == key)
    }
}

@Test func physicalKeyboardBindingsUseTheActualKeyCodes() {
    #expect(GameKeyboardKey.z.descriptor.code == "KeyZ")
    #expect(GameKeyboardKey.z.descriptor.keyCode == 90)
    #expect(GameKeyboardKey.x.descriptor.keyCode == 88)
    #expect(GameKeyboardKey.z.x11KeySym == 0x7A)
    #expect(GameKeyboardKey.x.x11KeySym == 0x78)
    #expect(GameKeyboardKey.pageUp.descriptor.keyCode == 33)
    #expect(GameKeyboardKey.pageUp.x11KeySym == 0xFF55)
    #expect(GameKeyboardKey.shift.keyCap == "Shift")
    #expect(GameKeyboardKey.numpad8.keyCap == "Num 8")
    #expect(GameKeyboardKey.numpad8.descriptor.location == 3)
    #expect(GameKeyboardKey.numpad8.x11KeySym == 0xFFB8)
    #expect(GameKeyboardKey.control.modifierOrder < GameKeyboardKey.z.modifierOrder)
    #expect(!GameKeyboardKey.z.isModifier)
    #expect(GameKeyboardKey.backquote.descriptor.key == "\u{0060}")
}
