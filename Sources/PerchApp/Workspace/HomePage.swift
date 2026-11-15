import PlannerCore
import PerchUI
import SwiftUI

/// Stable columns. Individual cards own their content, never the column widths.
struct HomePage: View {
    var body: some View {
        GeometryReader { geometry in
            let columns = HomeLayout.columns(sheetWidth: geometry.size.width)
            DotGridSheet {
                HStack(alignment: .top, spacing: HomeLayout.gap) {
                    // CHECKLIST CARD SLOT: replace this call only when the checklist lands.
                    TasksCard().frame(width: columns.checklist).frame(maxHeight: .infinity)
                    VStack(spacing: HomeLayout.gap) {
                        // TIME CARD SLOT: replace this call only when TimeCard lands.
                        FocusCard().frame(maxHeight: .infinity)
                        // PARKING LOT SLOT: replace this call only when ParkingLotCard lands.
                        NotepadCard().frame(height: HomeLayout.parkingHeight)
                    }
                    .frame(width: columns.time).frame(maxHeight: .infinity)
                    // YOUR DAY SLOT: this card owns its contents from here onward.
                    YourDayCard().frame(width: columns.day).frame(maxHeight: .infinity)
                }
            }
        }
    }
}
