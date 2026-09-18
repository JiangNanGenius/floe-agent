# Build187 native Office cover output

Source `d77aa11f7b4933b987faf5cf65ebc817d520e15e`, release run35312393708,
NativeNotes iPad Air13-inch M4 simulator component. These are original image
attachments, **not full-App library screenshots**. Root visually inspected all6.
The component gate failed a separate staging-count fixture; this folder does not
establish release acceptance. [Hashes and test identities](evidence.json).

The `*-summary.png` fixtures deliberately inject Quick Look failure and verify
real content summaries. `*-service.png` use the ordinary importer/CAS/service
path; Word and Excel returned system content, while PPT retained a labelled
summary. Summaries are bounded excerpts, not original document layout. The
system Excel thumbnail itself clips columns, so no complete-sheet fidelity is
claimed. Synthetic bilingual content contains no user data or credentials.

| Type | Explicit summary fallback | Service output |
| --- | --- | --- |
| Word | [Summary](word-summary.png) | [Service](word-service.png) |
| Excel | [Summary](excel-summary.png) | [Service](excel-service.png) |
| PowerPoint | [Summary](ppt-summary.png) | [Service](ppt-service.png) |
