gdjs.MainCode = {};
gdjs.MainCode.localVariables = [];
gdjs.MainCode.idToCallbackMap = new Map();
gdjs.MainCode.GDOrbObjects1= [];
gdjs.MainCode.GDOrbObjects2= [];


gdjs.MainCode.eventsList0 = function(runtimeScene) {

{


let isConditionTrue_0 = false;
isConditionTrue_0 = false;
isConditionTrue_0 = gdjs.evtTools.input.isKeyPressed(runtimeScene, "Right");
if (isConditionTrue_0) {
gdjs.copyArray(runtimeScene.getObjects("Orb"), gdjs.MainCode.GDOrbObjects1);
{for(var i = 0, len = gdjs.MainCode.GDOrbObjects1.length ;i < len;++i) {
    gdjs.MainCode.GDOrbObjects1[i].setX((gdjs.MainCode.GDOrbObjects1[i].getPointX("")) + 180 * gdjs.evtTools.runtimeScene.getElapsedTimeInSeconds(runtimeScene));
}
}
}

}


{


let isConditionTrue_0 = false;
isConditionTrue_0 = false;
isConditionTrue_0 = gdjs.evtTools.input.isKeyPressed(runtimeScene, "Left");
if (isConditionTrue_0) {
gdjs.copyArray(runtimeScene.getObjects("Orb"), gdjs.MainCode.GDOrbObjects1);
{for(var i = 0, len = gdjs.MainCode.GDOrbObjects1.length ;i < len;++i) {
    gdjs.MainCode.GDOrbObjects1[i].setX((gdjs.MainCode.GDOrbObjects1[i].getPointX("")) - 180 * gdjs.evtTools.runtimeScene.getElapsedTimeInSeconds(runtimeScene));
}
}
}

}


{


let isConditionTrue_0 = false;
isConditionTrue_0 = false;
isConditionTrue_0 = gdjs.evtTools.input.isKeyPressed(runtimeScene, "Up");
if (isConditionTrue_0) {
gdjs.copyArray(runtimeScene.getObjects("Orb"), gdjs.MainCode.GDOrbObjects1);
{for(var i = 0, len = gdjs.MainCode.GDOrbObjects1.length ;i < len;++i) {
    gdjs.MainCode.GDOrbObjects1[i].setY((gdjs.MainCode.GDOrbObjects1[i].getPointY("")) - 180 * gdjs.evtTools.runtimeScene.getElapsedTimeInSeconds(runtimeScene));
}
}
}

}


{


let isConditionTrue_0 = false;
isConditionTrue_0 = false;
isConditionTrue_0 = gdjs.evtTools.input.isKeyPressed(runtimeScene, "Down");
if (isConditionTrue_0) {
gdjs.copyArray(runtimeScene.getObjects("Orb"), gdjs.MainCode.GDOrbObjects1);
{for(var i = 0, len = gdjs.MainCode.GDOrbObjects1.length ;i < len;++i) {
    gdjs.MainCode.GDOrbObjects1[i].setY((gdjs.MainCode.GDOrbObjects1[i].getPointY("")) + 180 * gdjs.evtTools.runtimeScene.getElapsedTimeInSeconds(runtimeScene));
}
}
}

}


{


let isConditionTrue_0 = false;
isConditionTrue_0 = false;
isConditionTrue_0 = gdjs.evtTools.input.isKeyPressed(runtimeScene, "z");
if (isConditionTrue_0) {
gdjs.copyArray(runtimeScene.getObjects("Orb"), gdjs.MainCode.GDOrbObjects1);
{for(var i = 0, len = gdjs.MainCode.GDOrbObjects1.length ;i < len;++i) {
    gdjs.MainCode.GDOrbObjects1[i].setY(140);
}
}
{for(var i = 0, len = gdjs.MainCode.GDOrbObjects1.length ;i < len;++i) {
    gdjs.MainCode.GDOrbObjects1[i].setX(280);
}
}
}

}


};

gdjs.MainCode.func = function(runtimeScene) {
runtimeScene.getOnceTriggers().startNewFrame();

gdjs.MainCode.GDOrbObjects1.length = 0;
gdjs.MainCode.GDOrbObjects2.length = 0;

gdjs.MainCode.eventsList0(runtimeScene);
gdjs.MainCode.GDOrbObjects1.length = 0;
gdjs.MainCode.GDOrbObjects2.length = 0;


return;

}

gdjs['MainCode'] = gdjs.MainCode;
