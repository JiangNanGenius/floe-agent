# Build187 progressive cover fixture correction

The immutable build187 run35312393708 (source d77aa11f7b4933b987faf5cf65ebc817d520e15e)
failed the Notes functional gate on both devices:100/101 passed, with the same
`testSummaryGateBoundsCopiesAndReleasesBeforeTheQuickLookWait` assertion.
[Original structured results](notes-component.json) and the complete logs/xcresults remain retained.

The fixture queued three cards behind two held summary slots. Releasing one slot
allowed the first card to finish its summary and hand that slot directly to the
second card, which correctly staged its own summary while the first card's Quick
Look request was suspended. The fixture simultaneously expected that next summary
to own a slot and asserted that only the first card's Quick Look copy existed.
Both devices observed two copies. This is an inconsistent test observation, not
evidence that the first card retained its summary copy.

The correction queues a test-owned replacement holder immediately behind the
first card and ahead of the other cards. Once the first card releases its summary
slot, that holder prevents later cards from staging during the single-copy
assertion. Both external slots are then released, and the original assertions
still require all three first paints while Quick Look is held, only one staged
copy after summaries settle, exactly three system requests, and zero slots or
copies after completion. Cancellation releases the replacement holder as well.

No product source, timeout, retry, expected copy count, or release gate changed.
Six focused Swift6 semantic/object checks passed against existing SDK27 modules,
targeting iOS26; this is not execution. Dedicated cloud component run35314763193 at source
920132dcc88b448a5877fca3d61ea911afb69566 completed with the corrected staging-ownership test passing on both devices.
iPhone passed101/101; iPad passed100/101, with a different failure: the mind-map
WebKit test exceeded120 seconds during a GPU-process stall (the case later returned
at152.558 seconds, which does not erase the timeout). Strict Quick Look diagnostics
were retained separately. The original build187 release remains blocked, even if this
new test source passes separately.

## Artifact-only recovery conditions

A separate distribution controller is being prepared for this exact source pair.
It requires the original SDK27 and accepted-SDK jobs to finish successfully, the
original component failure to be exactly the reviewed case on both devices, and
the corrected component run to finish with101/101 and no skipped or expected
failures on both devices. The checker pins both commits and both fixture hashes,
and rejects any changed product source, resource, dependency, setting or workflow.
Only the reviewed test file and documentation differ. It also requires the
original upload to have been skipped, preventing an automatic duplicate upload.

This preserves the immutable App tag and reuses its qualified accepted-SDK input;
the supplementary test source and original failure remain explicitly recorded.
It is not the expedited path and grants no testing waiver. Signing, bundle/profile
checks and Apple validation remain the existing upload workflow. The original
release still reports failure; a successful recovery would be a separate run.

The original SDK27 full-App UI job also failed while querying a thumbnail child
inside a document Button. The later captured hierarchy does contain that child;
this establishes a costly/timed-out descendant query, not proof the thumbnail was
absent or the App main thread was deadlocked. Therefore the narrow artifact-only recovery controller
was not dispatched and cannot qualify this build. App-source repair requires a new
immutable build; the build187 recovery archive remains preserved.
