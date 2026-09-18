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
targeting iOS26; this is not execution. A dedicated cloud component rerun is the
next required check. The original build187 release remains blocked, even if this
new test source passes separately.
