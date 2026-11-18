// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeToolboxUtilities

/// One toolbox-owned model per instrument, retained across view reconstruction.
/// The location source is created only when the user opens that instrument.
@MainActor
public final class MacInstrumentModels {
    private let makeLocation: @MainActor () -> MacLocationModel
    private let makeRuler: @MainActor () -> MacRulerModel
    private let makePhoto: @MainActor () -> MacPhotoMeasureModel
    public private(set) lazy var location = makeLocation()
    public private(set) lazy var ruler = makeRuler()
    public private(set) lazy var photo = makePhoto()

    public init(activity: MacInstrumentActivityCoordinator,
                archive: ToolboxLocationArchive,
                rulerStore: MacRulerCalibrationStore,
                locationFactory: (@MainActor () -> MacLocationModel)? = nil,
                rulerFactory: (@MainActor () -> MacRulerModel)? = nil,
                photoFactory: (@MainActor () -> MacPhotoMeasureModel)? = nil) {
        makeLocation = locationFactory ?? { MacLocationModel(archive: archive, activity: activity) }
        makeRuler = rulerFactory ?? { MacRulerModel(store: rulerStore, activity: activity) }
        makePhoto = photoFactory ?? { MacPhotoMeasureModel(activity: activity) }
    }
}
