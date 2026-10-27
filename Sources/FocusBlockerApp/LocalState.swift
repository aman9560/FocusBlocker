import Combine
import SwiftUI

/// Stand-in for `@State`. In the macOS 27 SDK `@State` is a macro whose plugin ships only with Xcode, and this Mac
/// has just the Command Line Tools. `@StateObject` needs no macro, so this wraps the value in one. Behaves like
/// `@State` for these views; replace `@LocalState` with `@State` once Xcode is installed.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}
