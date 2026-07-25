import MeetingCore
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Meetings root: \(MeetingStore.defaultRoot.path)")
            .padding()
    }
}

#Preview {
    ContentView()
}
