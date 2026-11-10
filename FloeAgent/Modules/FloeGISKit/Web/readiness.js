// SPDX-License-Identifier: MPL-2.0
import { t } from '../../FloeHeavyEditorSupport/Web/runtime.js';

export const gisEditTools=new Set(['Point','LineString','Polygon','modify','translate']);

// Transient editor guidance, separate from geometry and the saved history.
export function gisEditNotice(tool,layer){
  if(!gisEditTools.has(tool))return null;
  if(!layer)return t('选择一个矢量图层后再绘制或编辑。','Choose a vector layer to draw or edit.');
  if(layer.kind!=='vector')return t('当前图层不是矢量图层，无法编辑几何。','The selected layer is not a vector layer.');
  if(layer.locked)return t('当前图层已锁定，解锁后才能编辑。','This layer is locked. Unlock it to edit.');
  return null;
}
