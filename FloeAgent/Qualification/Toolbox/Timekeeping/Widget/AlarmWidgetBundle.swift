// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import WidgetKit

/// Wrapper only: both the alarm rendering and controls are production files.
@main struct AlarmQualificationWidgetBundle: WidgetBundle {
    var body: some Widget { FloeSystemAlarmLiveActivityWidget() }
}
