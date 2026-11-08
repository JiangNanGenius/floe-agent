// SPDX-License-Identifier: MPL-2.0
// Presentation routing only. All edits continue through the bundled commands.
export const outlineInputCanEdit=(kind,fingerDrawing=false)=>kind==='mouse'||kind==='pen'||kind==='touch'&&fingerDrawing===true;
