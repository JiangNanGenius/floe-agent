//
//  VideoEditorToolContentView.swift
//  VideoEditorKit
//
//  Created by Codex on 09.04.2026.
//

import SwiftUI

struct VideoEditorToolContentView: View {

    // MARK: - Bindings

    @Binding private var draftState: EditorToolDraftState

    // MARK: - Public Properties

    let tool: ToolEnum
    let editorViewModel: EditorViewModel
    let videoPlayer: VideoPlayerManager

    // MARK: - Body

    var body: some View {
        switch tool {
        case .speed:
            VideoSpeedToolView(selectedRate: draftState.speedDraft) { rate in
                draftState = HostedVideoEditorToolActionCoordinator.selectSpeed(
                    rate,
                    currentDraftState: draftState,
                    editorViewModel: editorViewModel,
                    videoPlayer: videoPlayer
                )
            }
        case .presets:
            PresentToolView(
                selectedPreset: draftState.presetDraft,
                onSelect: { preset in
                    draftState = HostedVideoEditorToolActionCoordinator.selectPreset(
                        preset,
                        currentDraftState: draftState,
                        editorViewModel: editorViewModel
                    )
                }
            )
        case .audio:
            VideoAudioToolView(
                draft: draftState.audioDraft,
                hasRecordedAudioTrack: editorViewModel.hasRecordedAudioTrack,
                onSelectTrack: { track in
                    draftState = HostedVideoEditorToolActionCoordinator.selectAudioTrack(
                        track,
                        currentDraftState: draftState,
                        editorViewModel: editorViewModel
                    )
                },
                onChangeVolume: { value in
                    draftState = HostedVideoEditorToolActionCoordinator.updateAudioVolume(
                        value,
                        currentDraftState: draftState,
                        editorViewModel: editorViewModel,
                        videoPlayer: videoPlayer
                    )
                },
                onFinishVolumeChange: {
                    HostedVideoEditorToolActionCoordinator.finishAudioEditing(
                        editorViewModel: editorViewModel
                    )
                }
            )
        case .adjusts:
            VideoAdjustsToolView(adjusts: draftState.adjustsDraft) { adjusts in
                draftState = HostedVideoEditorToolActionCoordinator.updateAdjusts(
                    adjusts,
                    currentDraftState: draftState,
                    editorViewModel: editorViewModel,
                    videoPlayer: videoPlayer
                )
            }
        case .transcript:
            TranscriptToolView(
                isTranscriptionAvailable: editorViewModel.isTranscriptionAvailable,
                transcriptState: editorViewModel.transcriptState,
                document: editorViewModel.transcriptDraftDocument,
                onCopyTranscript: { text in
                    PlainTextClipboard.copy(text)
                },
                onUpdateSegmentText: { segmentID, text in
                    editorViewModel.updateTranscriptSegmentText(
                        text,
                        segmentID: segmentID
                    )
                },
                onRevertSegmentText: { segmentID in
                    editorViewModel.revertTranscriptSegmentText(segmentID: segmentID)
                },
                onUpdatePosition: { position in
                    editorViewModel.updateTranscriptOverlayPosition(position)
                },
                onUpdateSize: { size in
                    editorViewModel.updateTranscriptOverlaySize(size)
                }
            )
        case .cut:
            EmptyView()
        }
    }

    // MARK: - Initializer

    init(
        tool: ToolEnum,
        draftState: Binding<EditorToolDraftState>,
        editorViewModel: EditorViewModel,
        videoPlayer: VideoPlayerManager
    ) {
        self.tool = tool
        _draftState = draftState

        self.editorViewModel = editorViewModel
        self.videoPlayer = videoPlayer
    }

}

#Preview {
    @Previewable @State var draftState = EditorToolDraftState()
    NavigationStack {
        VideoEditorToolContentView(
            tool: .speed,
            draftState: $draftState,
            editorViewModel: EditorViewModel(),
            videoPlayer: VideoPlayerManager()
        )
    }
}
