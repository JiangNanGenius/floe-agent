#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Generate an original Unity 2022.3 LTS starter project.

The project contains original C# source, a minimal standard scene, versioned
project metadata and an Editor WebGL build bootstrap. It bundles no Unity engine
code, packages, third-party art or prebuilt WebGL output. A licensed Unity
editor with WebGL Build Support is an explicit user prerequisite; no build was
executed by this fixture generator.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_legacy_rpg import MIT_TEXT, OUT  # noqa: E402


NAME = "unity"
ROOT = OUT / NAME
UNITY_VERSION = "2022.3.0f1"
UNITY_REVISION = "fb119bb0b476"
SCENE_GUID = "8f4c2d1e5a6b47c8d9e0f1a2b3c4d5e6"
SCRIPT_GUID = "1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6"
EDITOR_GUID = "2b3c4d5e6f7a48b9c0d1e2f3a4b5c6d7"

CS_SOURCE = r"""// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
using System;
using UnityEngine;

/// <summary>
/// Original, self-contained Floe starter for Unity. It builds the whole scene at
/// runtime with standard UnityEngine APIs and draws its UI with IMGUI, so the
/// project needs no imported art, prefabs or third-party packages.
/// </summary>
public sealed class FloeStarter : MonoBehaviour
{
    private const float Width = 816f;
    private const float Height = 624f;
    private const float Tile = 48f;
    private const string SaveKey = "floe.glimmerfen.save.v1";

    [Serializable]
    private sealed class SaveData
    {
        public int version;
        public int x;
        public int y;
        public int steps;
        public int score;
    }

    private int playerX = 2;
    private int playerY = 2;
    private int steps;
    private int score;
    private bool menu;
    private int menuIndex;
    private string message = string.Empty;
    private float messageUntil;
    private Texture2D white;
    private Texture2D player;
    private Texture2D coin;

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void Bootstrap()
    {
        if (FindObjectOfType<FloeStarter>() != null) return;
        var root = new GameObject("Floe Starter");
        root.AddComponent<FloeStarter>();
    }

    private void Awake()
    {
        DontDestroyOnLoad(gameObject);
        if (Camera.main == null)
        {
            var cameraObject = new GameObject("Floe Camera");
            var camera = cameraObject.AddComponent<Camera>();
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(0.055f, 0.11f, 0.094f, 1f);
            camera.orthographic = true;
            camera.orthographicSize = Height / 2f;
            cameraObject.tag = "MainCamera";
        }
        white = MakeTexture(1, 1, Color.white);
        player = MakeCircleTexture(32, new Color(0.56f, 0.84f, 1f, 1f));
        coin = MakeCircleTexture(20, new Color(1f, 0.81f, 0.33f, 1f));
    }

    private static Texture2D MakeTexture(int width, int height, Color color)
    {
        var texture = new Texture2D(width, height, TextureFormat.RGBA32, false);
        var pixels = new Color[width * height];
        for (var i = 0; i < pixels.Length; i++) pixels[i] = color;
        texture.SetPixels(pixels);
        texture.Apply();
        return texture;
    }

    private static Texture2D MakeCircleTexture(int size, Color color)
    {
        var texture = new Texture2D(size, size, TextureFormat.RGBA32, false);
        var pixels = new Color[size * size];
        var center = (size - 1) / 2f;
        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var dx = x - center;
                var dy = y - center;
                pixels[y * size + x] = dx * dx + dy * dy <= (size * 0.42f) * (size * 0.42f)
                    ? color : Color.clear;
            }
        }
        texture.SetPixels(pixels);
        texture.Apply();
        return texture;
    }

    private void Update()
    {
        if (messageUntil > 0f && Time.time > messageUntil) message = string.Empty;
        if (menu)
        {
            if (Input.GetKeyDown(KeyCode.UpArrow)) menuIndex = (menuIndex + 2) % 3;
            if (Input.GetKeyDown(KeyCode.DownArrow)) menuIndex = (menuIndex + 1) % 3;
            if (ConfirmPressed())
            {
                if (menuIndex == 1) SaveGame();
                if (menuIndex == 2) LoadGame();
                menu = false;
            }
            if (CancelPressed()) menu = false;
            return;
        }
        if (CancelPressed())
        {
            menu = true;
            menuIndex = 0;
            return;
        }
        if (ConfirmPressed())
        {
            var near = (playerX == 4 && playerY == 3) || (playerX == 8 && playerY == 6);
            Say(near ? "The ferry keeper nods. One rope coil, one crossing."
                     : "The fen is quiet. The ferry waits to the east.");
            if (playerX == 8 && playerY == 6 && score == 0)
            {
                score = 1;
                Say("You pocket a coil of rope from the notice stone.");
            }
            return;
        }
        if (Input.GetKey(KeyCode.LeftArrow)) Move(-1, 0);
        else if (Input.GetKey(KeyCode.RightArrow)) Move(1, 0);
        else if (Input.GetKey(KeyCode.UpArrow)) Move(0, -1);
        else if (Input.GetKey(KeyCode.DownArrow)) Move(0, 1);
        if (Input.GetKeyDown(KeyCode.F5)) SaveGame();
        if (Input.GetKeyDown(KeyCode.F9)) LoadGame();
        if (Input.GetKeyDown(KeyCode.Q)) menuIndex = (menuIndex + 2) % 3;
        if (Input.GetKeyDown(KeyCode.W)) menuIndex = (menuIndex + 1) % 3;
    }

    private static bool ConfirmPressed()
    {
        return Input.GetKeyDown(KeyCode.Z) || Input.GetKeyDown(KeyCode.Return) ||
               Input.GetKeyDown(KeyCode.Space);
    }

    private static bool CancelPressed()
    {
        return Input.GetKeyDown(KeyCode.X) || Input.GetKeyDown(KeyCode.Escape);
    }

    private void Move(int dx, int dy)
    {
        var nx = Mathf.Clamp(playerX + dx, 0, 11);
        var ny = Mathf.Clamp(playerY + dy, 0, 9);
        if (nx == playerX && ny == playerY) return;
        playerX = nx;
        playerY = ny;
        steps++;
        if (playerX == 8 && playerY == 6 && score == 0)
        {
            score = 1;
            Say("You pocket a coil of rope from the notice stone.");
        }
    }

    private void Say(string text)
    {
        message = text;
        messageUntil = Time.time + 4f;
    }

    private void SaveGame()
    {
        var data = new SaveData { version = 1, x = playerX, y = playerY, steps = steps, score = score };
        PlayerPrefs.SetString(SaveKey, JsonUtility.ToJson(data));
        PlayerPrefs.Save();
        Say("Saved to PlayerPrefs.");
    }

    private void LoadGame()
    {
        var raw = PlayerPrefs.GetString(SaveKey, string.Empty);
        if (string.IsNullOrEmpty(raw))
        {
            Say("No save yet.");
            return;
        }
        try
        {
            var data = JsonUtility.FromJson<SaveData>(raw);
            if (data == null || data.version != 1) { Say("That save is not compatible."); return; }
            playerX = Mathf.Clamp(data.x, 0, 11);
            playerY = Mathf.Clamp(data.y, 0, 9);
            steps = Mathf.Max(0, data.steps);
            score = Mathf.Clamp(data.score, 0, 1);
            Say("Loaded from PlayerPrefs.");
        }
        catch (Exception)
        {
            Say("The save could not be read.");
        }
    }

    private void OnGUI()
    {
        var scale = Mathf.Min(Screen.width / Width, Screen.height / Height);
        var offsetX = (Screen.width - Width * scale) / 2f;
        var offsetY = (Screen.height - Height * scale) / 2f;
        GUI.matrix = Matrix4x4.TRS(new Vector3(offsetX, offsetY, 0f),
            Quaternion.identity, new Vector3(scale, scale, 1f));
        GUI.color = new Color(0.075f, 0.137f, 0.118f, 1f);
        GUI.DrawTexture(new Rect(0, 0, Width, Height), white);
        for (var y = 0; y < 10; y++)
        {
            for (var x = 0; x < 12; x++)
            {
                var edge = x == 0 || y == 0 || x == 11 || y == 9;
                GUI.color = edge ? new Color(0.15f, 0.24f, 0.20f, 1f)
                                 : new Color(0.12f + (x + y) % 3 * 0.015f,
                                             0.23f + (x * 3 + y) % 4 * 0.012f, 0.185f, 1f);
                GUI.DrawTexture(new Rect(x * Tile + 2, y * Tile + 2, Tile - 4, Tile - 4), white);
            }
        }
        if (score == 0)
        {
            GUI.color = Color.white;
            GUI.DrawTexture(new Rect(8 * Tile + 14, 6 * Tile + 14, 20, 20), coin);
        }
        GUI.color = Color.white;
        GUI.DrawTexture(new Rect(playerX * Tile + 8, playerY * Tile + 8, 32, 32), player);
        GUI.color = new Color(0.93f, 0.94f, 0.85f, 1f);
        GUI.Label(new Rect(16, 12, 600, 30), $"Glimmerfen   steps {steps}   rope {score}/1");
        GUI.Label(new Rect(600, 12, 200, 30), "C talk   B menu");
        if (!string.IsNullOrEmpty(message))
        {
            GUI.color = new Color(0.07f, 0.12f, 0.10f, 0.92f);
            GUI.DrawTexture(new Rect(0, Height - 92, Width, 92), white);
            GUI.color = new Color(0.96f, 0.94f, 0.82f, 1f);
            GUI.Label(new Rect(18, Height - 72, Width - 36, 60), message);
        }
        if (menu)
        {
            GUI.color = new Color(0.08f, 0.14f, 0.12f, 0.96f);
            GUI.DrawTexture(new Rect(250, 170, 260, 150), white);
            GUI.color = new Color(1f, 0.88f, 0.55f, 1f);
            var items = new[] { "Resume", "Save", "Load" };
            for (var i = 0; i < items.Length; i++)
            {
                GUI.Label(new Rect(275, 185 + i * 36, 220, 30),
                    (i == menuIndex ? "▶ " : "  ") + items[i]);
            }
        }
    }
}
"""

EDITOR_SOURCE = r"""// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
#if UNITY_EDITOR
using System;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

/// <summary>
/// Original Floe WebGL build bootstrap for the pinned Unity 2022.3 LTS editor.
/// The build is performed by the user's licensed Unity installation; this
/// package does not include or claim a produced WebGL artifact.
/// </summary>
public static class FloeWebBuild
{
    [MenuItem("Floe/Build WebGL")]
    public static void BuildFromMenu() => Build("Build/WebGL");

    public static void BuildFromCommandLine() => Build("Build/WebGL");

    private static void Build(string outputPath)
    {
        var options = new BuildPlayerOptions
        {
            scenes = new[] { "Assets/Scenes/Main.unity" },
            locationPathName = outputPath,
            target = BuildTarget.WebGL,
            options = BuildOptions.None,
        };
        var report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result != BuildResult.Succeeded)
        {
            throw new Exception("Floe WebGL build failed: " + report.summary.result);
        }
        Debug.Log("Floe WebGL build succeeded: " + outputPath);
    }
}
#endif
"""

SCENE = """%YAML 1.1
%TAG !u! tag:unity3d.com,2011:
--- !u!29 &1
OcclusionCullingSettings:
  m_ObjectHideFlags: 0
  serializedVersion: 2
  m_OcclusionBakeSettings:
    smallestOccluder: 5
    smallestHole: 0.25
    backfaceThreshold: 100
  m_SceneGUID: 00000000000000000000000000000000
  m_OcclusionCullingData: {fileID: 0}
--- !u!104 &2
RenderSettings:
  m_ObjectHideFlags: 0
  serializedVersion: 9
  m_Fog: 0
  m_FogColor: {r: 0.5, g: 0.5, b: 0.5, a: 1}
  m_FogMode: 3
  m_FogDensity: 0.01
  m_LinearFogStart: 0
  m_LinearFogEnd: 300
  m_AmbientSkyColor: {r: 0.212, g: 0.227, b: 0.259, a: 1}
  m_AmbientEquatorColor: {r: 0.114, g: 0.125, b: 0.133, a: 1}
  m_AmbientGroundColor: {r: 0.047, g: 0.043, b: 0.035, a: 1}
  m_AmbientIntensity: 1
  m_AmbientMode: 0
  m_SubtractiveShadowColor: {r: 0.42, g: 0.478, b: 0.627, a: 1}
  m_SkyboxMaterial: {fileID: 0}
  m_HaloStrength: 0.5
  m_FlareStrength: 1
  m_FlareFadeSpeed: 3
  m_HaloTexture: {fileID: 0}
  m_SpotCookie: {fileID: 0}
  m_DefaultReflectionMode: 0
  m_DefaultReflectionResolution: 128
  m_ReflectionBounces: 1
  m_ReflectionIntensity: 1
  m_CustomReflection: {fileID: 0}
  m_Sun: {fileID: 0}
  m_IndirectSpecularColor: {r: 0, g: 0, b: 0, a: 1}
  m_UseRadianceAmbientProbe: 0
--- !u!157 &3
LightmapSettings:
  m_ObjectHideFlags: 0
  serializedVersion: 12
  m_GIWorkflowMode: 1
  m_GISettings:
    serializedVersion: 2
    m_BounceScale: 1
    m_IndirectOutputScale: 1
    m_AlbedoBoost: 1
    m_EnvironmentLightingMode: 0
    m_EnableBakedLightmaps: 0
    m_EnableRealtimeLightmaps: 0
  m_LightmapEditorSettings:
    serializedVersion: 12
    m_Resolution: 2
    m_BakeResolution: 40
    m_AtlasSize: 1024
    m_AO: 0
    m_AOMaxDistance: 1
    m_CompAOExponent: 1
    m_CompAOExponentDirect: 0
    m_ExtractAmbientOcclusion: 0
    m_Padding: 2
    m_LightmapParameters: {fileID: 0}
    m_LightmapsBakeMode: 1
    m_TextureCompression: 1
    m_FinalGather: 0
    m_FinalGatherFiltering: 1
    m_FinalGatherRayCount: 256
    m_ReflectionCompression: 2
    m_MixedBakeMode: 2
    m_BakeBackend: 1
    m_PVRSampling: 1
    m_PVRDirectSampleCount: 32
    m_PVRSampleCount: 512
    m_PVRBounces: 2
    m_PVREnvironmentSampleCount: 256
    m_PVREnvironmentReferencePointCount: 2048
    m_PVRFilteringMode: 1
    m_PVRDenoiserTypeDirect: 1
    m_PVRDenoiserTypeIndirect: 1
    m_PVRDenoiserTypeAO: 1
    m_PVRFilterTypeDirect: 0
    m_PVRFilterTypeIndirect: 0
    m_PVRFilterTypeAO: 0
    m_PVREnvironmentMIS: 1
    m_PVRCulling: 1
    m_PVRFilteringGaussRadiusDirect: 1
    m_PVRFilteringGaussRadiusIndirect: 5
    m_PVRFilteringGaussRadiusAO: 2
    m_PVRFilteringAtrousPositionSigmaDirect: 0.5
    m_PVRFilteringAtrousPositionSigmaIndirect: 2
    m_PVRFilteringAtrousPositionSigmaAO: 1
    m_ExportTrainingData: 0
    m_TrainingDataDestination: TrainingData
    m_LightProbeSampleCountMultiplier: 4
  m_LightingDataAsset: {fileID: 0}
  m_LightingSettings: {fileID: 0}
--- !u!196 &4
NavMeshSettings:
  serializedVersion: 2
  m_ObjectHideFlags: 0
  m_BuildSettings:
    serializedVersion: 3
    agentTypeID: 0
    agentRadius: 0.5
    agentHeight: 2
    agentSlope: 45
    agentClimb: 0.4
    ledgeDropHeight: 0
    maxJumpAcrossDistance: 0
    minRegionArea: 2
    manualCellSize: 0
    cellSize: 0.16666667
    manualTileSize: 0
    tileSize: 256
    buildHeightMesh: 0
    maxJobWorkers: 0
    preserveTilesOutsideBounds: 0
    debug:
      m_Flags: 0
  m_NavMeshData: {fileID: 0}
"""


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def generate() -> dict:
    if ROOT.exists():
        shutil.rmtree(ROOT)
    ROOT.mkdir(parents=True)
    write(ROOT / "ProjectSettings/ProjectVersion.txt",
          f"m_EditorVersion: {UNITY_VERSION}\nm_EditorVersionWithRevision: {UNITY_VERSION} ({UNITY_REVISION})\n")
    write(ROOT / "ProjectSettings/ProjectSettings.asset", f"""%YAML 1.1
%TAG !u! tag:unity3d.com,2011:
--- !u!129 &1
PlayerSettings:
  m_ObjectHideFlags: 0
  serializedVersion: 26
  productGUID: 6d4e2c1b8a7f43e9b0d5c6a7f8e9d0c1
  AndroidProfiler: 0
  companyName: Floe
  productName: Glimmerfen
  defaultScreenWidth: 816
  defaultScreenHeight: 624
  defaultScreenWidthWeb: 816
  defaultScreenHeightWeb: 624
  m_StereoRenderingPath: 0
  m_ActiveColorSpace: 0
  unsupportedMSAAFallback: 0
  m_SpriteBatchVertexThreshold: 300
  m_MTRendering: 1
  mipStripping: 0
  numberOfMipsStripped: 0
  numberOfMipsStrippedPerMipmapLimitGroup: {{}}
  m_StackTraceTypes: 010000000100000001000000010000000100000001000000
  iosShowActivityIndicatorOnLoading: -1
  androidShowActivityIndicatorOnLoading: -1
  iosUseCustomAppBackgroundBehavior: 0
  allowedAutorotateToPortrait: 1
  allowedAutorotateToPortraitUpsideDown: 1
  allowedAutorotateToLandscapeRight: 1
  allowedAutorotateToLandscapeLeft: 1
  useOSAutorotation: 1
  use32BitDisplayBuffer: 1
  preserveFramebufferAlpha: 0
  disableDepthAndStencilBuffers: 0
  androidStartInFullscreen: 1
  androidRenderOutsideSafeArea: 1
  androidUseSwappy: 1
  androidBlitType: 0
  androidResizableWindow: 0
  androidDefaultWindowWidth: 1920
  androidDefaultWindowHeight: 1080
  androidMinimumWindowWidth: 400
  androidMinimumWindowHeight: 300
  androidFullscreenMode: 1
  defaultIsNativeResolution: 1
  macRetinaSupport: 1
  runInBackground: 1
  captureSingleScreen: 0
  muteOtherAudioSources: 0
  Prepare IOS For Recording: 0
  Force IOS Speakers When Recording: 0
  deferSystemGesturesMode: 0
  hideHomeButton: 0
  submitAnalytics: 1
  usePlayerLog: 1
  dedicatedServerOptimizations: 0
  bakeCollisionMeshes: 0
  forceSingleInstance: 0
  useFlipModelSwapchain: 1
  resizableWindow: 1
  useMacAppStoreValidation: 0
  macAppStoreCategory: public.app-category.games
  gpuSkinning: 1
  xboxPIXTextureCapture: 0
  xboxEnableAvatar: 0
  xboxEnableKinect: 0
  xboxEnableKinectAutoTracking: 0
  xboxEnableFitness: 0
  visibleInBackground: 1
  allowFullscreenSwitch: 1
  fullscreenMode: 3
  xboxSpeechDB: 0
  xboxEnableHeadOrientation: 0
  xboxEnableGuest: 0
  xboxEnablePIXSampling: 0
  metalFramebufferOnly: 0
  xboxOneResolution: 0
  xboxOneSResolution: 0
  xboxOneXResolution: 3
  xboxOneMonoLoggingLevel: 0
  xboxOneLoggingLevel: 1
  xboxOneDisableEsram: 0
  xboxOneEnableTypeOptimization: 0
  xboxOnePresentImmediateThreshold: 0
  switchQueueCommandMemory: 1048576
  switchQueueControlMemory: 16384
  switchQueueComputeMemory: 262144
  switchNVNShaderPoolsGranularity: 33554432
  switchNVNDefaultPoolsGranularity: 16777216
  switchNVNOtherPoolsGranularity: 16777216
  switchNVNMaxPublicTextureIDCount: 0
  switchNVNMaxPublicSamplerIDCount: 0
  stadiaPresentMode: 0
  stadiaTargetFramerate: 0
  vulkanNumSwapchainBuffers: 3
  vulkanEnableSetSRGBWrite: 0
  vulkanEnablePreTransform: 0
  vulkanEnableLateAcquireNextImage: 0
  vulkanEnableCommandBufferRecycling: 1
  loadStoreDebugModeEnabled: 0
  bundleVersion: 1.0.0
  preloadedAssets: []
  metroInputSource: 0
  wsaTransparentSwapchain: 0
  m_HolographicPauseOnTrackingLoss: 1
  xboxOneDisableKinectGpuReservation: 1
  xboxOneEnable7thCore: 1
  vrSettings:
    enable360StereoCapture: 0
  isWsaHolographicRemotingEnabled: 0
  enableFrameTimingStats: 0
  enableOpenGLProfilerGPURecorders: 1
  allowHDRDisplaySupport: 0
  useHDRDisplay: 0
  hdrBitDepth: 0
  m_ColorGamuts: 00000000
  targetPixelDensity: 30
  resolutionScalingMode: 0
  resetResolutionOnWindowResize: 0
  androidSupportedAspectRatio: 1
  androidMaxAspectRatio: 2.1
  applicationIdentifier:
    Standalone: com.floe.glimmerfen
    WebGL: com.floe.glimmerfen
  buildNumber:
    Standalone: 0
    WebGL: 0
  overrideDefaultApplicationIdentifier: 0
  AndroidBundleVersionCode: 1
  AndroidMinSdkVersion: 22
  AndroidTargetSdkVersion: 0
  AndroidPreferredInstallLocation: 1
  aotOptions: nimt-trampolines=1024
  stripEngineCode: 1
  iPhoneStrippingLevel: 0
  iPhoneScriptCallOptimization: 0
  ForceInternetPermission: 0
  ForceSDCardPermission: 0
  CreateWallpaper: 0
  APKExpansionFiles: 0
  keepLoadedShadersAlive: 0
  StripUnusedMeshComponents: 0
  strictShaderVariantMatching: 0
  VertexChannelCompressionMask: 4054
  iPhoneSdkVersion: 988
  iOSTargetOSVersionString: 12.0
  tvOSSdkVersion: 0
  tvOSRequireExtendedGameController: 0
  tvOSTargetOSVersionString: 12.0
  uIPrerenderedIcon: 0
  uIRequiresPersistentWiFi: 0
  uIRequiresFullScreen: 1
  uIStatusBarHidden: 1
  uIExitOnSuspend: 0
  uIStatusBarStyle: 0
  appleTVSplashScreen: {{fileID: 0}}
  appleTVSplashScreen2x: {{fileID: 0}}
  tvOSSmallIconLayers: []
  tvOSSmallIconLayers2x: []
  tvOSLargeIconLayers: []
  tvOSLargeIconLayers2x: []
  tvOSTopShelfImageLayers: []
  tvOSTopShelfImageLayers2x: []
  tvOSTopShelfImageWideLayers: []
  tvOSTopShelfImageWideLayers2x: []
  iOSLaunchScreenType: 0
  iOSLaunchScreenPortrait: {{fileID: 0}}
  iOSLaunchScreenLandscape: {{fileID: 0}}
  iOSLaunchScreenBackgroundColor:
    serializedVersion: 2
    rgba: 0
  iOSLaunchScreenFillPct: 100
  iOSLaunchScreenSize: 100
  iOSLaunchScreenCustomXibPath: 
  iOSLaunchScreeniPadType: 0
  iOSLaunchScreeniPadImage: {{fileID: 0}}
  iOSLaunchScreeniPadBackgroundColor:
    serializedVersion: 2
    rgba: 0
  iOSLaunchScreeniPadFillPct: 100
  iOSLaunchScreeniPadSize: 100
  iOSLaunchScreeniPadCustomXibPath: 
  iOSLaunchScreenCustomStoryboardPath: 
  iOSLaunchScreeniPadCustomStoryboardPath: 
  iOSDeviceRequirements: []
  iOSURLSchemes: []
  macOSURLSchemes: []
  iOSBackgroundModes: 0
  iOSMetalForceHardShadows: 0
  metalEditorSupport: 1
  metalAPIValidation: 1
  iOSRenderExtraFrameOnPause: 0
  iosCopyPluginsCodeInsteadOfSymlink: 0
  appleDeveloperTeamID: 
  iOSManualSigningProvisioningProfileID: 
  tvOSManualSigningProvisioningProfileID: 
  iOSManualSigningProvisioningProfileType: 0
  tvOSManualSigningProvisioningProfileType: 0
  appleEnableAutomaticSigning: 0
  iOSRequireARKit: 0
  iOSAutomaticallyDetectAndAddCapabilities: 1
  appleEnableProMotion: 0
  shaderPrecisionModel: 0
  clonedFromGUID: 00000000000000000000000000000000
  templatePackageId: com.unity.template.2d@6.1.1
  templateDefaultScene: Assets/Scenes/Main.unity
  useCustomMainManifest: 0
  useCustomLauncherManifest: 0
  useCustomMainGradleTemplate: 0
  useCustomLauncherGradleManifest: 0
  useCustomBaseGradleTemplate: 0
  useCustomGradlePropertiesTemplate: 0
  useCustomGradleSettingsTemplate: 0
  useCustomProguardFile: 0
  AndroidTargetArchitectures: 1
  AndroidTargetDevices: 0
  AndroidSplashScreenScale: 0
  androidSplashScreen: {{fileID: 0}}
  AndroidKeystoreName: 
  AndroidKeyaliasName: 
  AndroidEnableArmv9SecurityFeatures: 0
  AndroidBuildApkPerCpuArchitecture: 0
  AndroidTVCompatibility: 0
  AndroidIsGame: 1
  AndroidEnableTango: 0
  androidEnableBanner: 1
  androidUseLowAccuracyLocation: 0
  androidUseCustomKeystore: 0
  m_AndroidBanners:
  - width: 320
    height: 180
    banner: {{fileID: 0}}
  androidGamepadSupportLevel: 0
  chromeosInputEmulation: 1
  AndroidMinifyRelease: 0
  AndroidMinifyDebug: 0
  AndroidValidateAppBundleSize: 1
  AndroidAppBundleSizeToValidate: 150
  m_BuildTargetIcons: []
  m_BuildTargetPlatformIcons: []
  m_BuildTargetBatching:
  - m_BuildTarget: Standalone
    m_StaticBatching: 1
    m_DynamicBatching: 0
  - m_BuildTarget: WebGL
    m_StaticBatching: 0
    m_DynamicBatching: 0
  m_BuildTargetShaderSettings: []
  m_BuildTargetGraphicsJobs:
  - m_BuildTarget: WebGL
    m_GraphicsJobs: 0
  m_BuildTargetGraphicsJobMode: []
  m_BuildTargetGraphicsAPIs:
  - m_BuildTarget: WebGL
    m_APIs: 0b000000
    m_Automatic: 0
  m_BuildTargetVRSettings: []
  m_DefaultShaderChunkSizeInMB: 16
  m_DefaultShaderChunkCount: 0
  openGLRequireES31: 0
  openGLRequireES31AEP: 0
  openGLRequireES32: 0
  m_TemplateCustomTags: {{}}
  mobileMTRendering:
    Android: 1
    iPhone: 1
    tvOS: 1
  m_BuildTargetGroupLightmapEncodingQuality:
  - m_BuildTarget: Standalone
    m_EncodingQuality: 1
  - m_BuildTarget: WebGL
    m_EncodingQuality: 1
  m_BuildTargetGroupLightmapSettings: []
  m_BuildTargetNormalMapEncoding: []
  m_BuildTargetDefaultTextureCompressionFormat: []
  playModeTestRunnerEnabled: 0
  runPlayModeTestAsEditModeTest: 0
  actionOnDotNetUnhandledException: 1
  enableInternalProfiler: 0
  logObjCUncaughtExceptions: 1
  enableCrashReportAPI: 0
  cameraUsageDescription: 
  locationUsageDescription: 
  microphoneUsageDescription: 
  bluetoothUsageDescription: 
  macOSTargetOSVersion: 10.13.0
  switchNMETAOverride: 
  switchNetLibKey: 
  switchSocketMemoryPoolSize: 6144
  switchSocketAllocatorPoolSize: 128
  switchSocketConcurrencyLimit: 14
  switchScreenResolutionBehavior: 2
  switchUseCPUProfiler: 0
  switchEnableFileSystemTrace: 0
  switchLTOSetting: 0
  switchApplicationID: 0x01004b9000490000
  switchNSODependencies: 
  switchCompilerFlags: 
  switchTitleNames_0: 
  switchTitleNames_1: 
  switchTitleNames_2: 
  switchTitleNames_3: 
  switchTitleNames_4: 
  switchTitleNames_5: 
  switchTitleNames_6: 
  switchTitleNames_7: 
  switchTitleNames_8: 
  switchTitleNames_9: 
  switchTitleNames_10: 
  switchTitleNames_11: 
  switchTitleNames_12: 
  switchTitleNames_13: 
  switchTitleNames_14: 
  switchTitleNames_15: 
  switchPublisherNames_0: 
  switchPublisherNames_1: 
  switchPublisherNames_2: 
  switchPublisherNames_3: 
  switchPublisherNames_4: 
  switchPublisherNames_5: 
  switchPublisherNames_6: 
  switchPublisherNames_7: 
  switchPublisherNames_8: 
  switchPublisherNames_9: 
  switchPublisherNames_10: 
  switchPublisherNames_11: 
  switchPublisherNames_12: 
  switchPublisherNames_13: 
  switchPublisherNames_14: 
  switchPublisherNames_15: 
  switchIcons_0: {{fileID: 0}}
  switchSmallIcons_0: {{fileID: 0}}
  switchManualHTML: 
  switchAccessibleURLs: 
  switchLegalInformation: 
  switchMainThreadStackSize: 1048576
  switchPresenceGroupId: 
  switchLogoHandling: 0
  switchReleaseVersion: 0
  switchDisplayVersion: 1.0.0
  switchStartupUserAccount: 0
  switchSupportedLanguagesMask: 0
  switchLogoType: 0
  switchApplicationErrorCodeCategory: 
  switchUserAccountSaveDataSize: 0
  switchUserAccountSaveDataJournalSize: 0
  switchApplicationAttribute: 0
  switchCardSpecSize: -1
  switchCardSpecClock: -1
  switchRatingsMask: 0
  switchRatingsInt_0: 0
  switchRatingsInt_1: 0
  switchRatingsInt_2: 0
  switchRatingsInt_3: 0
  switchRatingsInt_4: 0
  switchRatingsInt_5: 0
  switchRatingsInt_6: 0
  switchRatingsInt_7: 0
  switchRatingsInt_8: 0
  switchRatingsInt_9: 0
  switchRatingsInt_10: 0
  switchRatingsInt_11: 0
  switchRatingsInt_12: 0
  switchLocalCommunicationIds_0: 
  switchLocalCommunicationIds_1: 
  switchLocalCommunicationIds_2: 
  switchLocalCommunicationIds_3: 
  switchLocalCommunicationIds_4: 
  switchLocalCommunicationIds_5: 
  switchLocalCommunicationIds_6: 
  switchLocalCommunicationIds_7: 
  switchParentalControl: 0
  switchAllowsScreenshot: 1
  switchAllowsVideoCapturing: 1
  switchAllowsRuntimeAddOnContentInstall: 0
  switchDataLossConfirmation: 0
  switchUserAccountLockEnabled: 0
  switchSystemResourceMemory: 16777216
  switchSupportedNpadStyles: 22
  switchNativeFsCacheSize: 32
  switchIsHoldTypeHorizontal: 0
  switchSupportedNpadCount: 8
  switchEnableTouchScreen: 1
  switchSocketConfigEnabled: 0
  switchTcpInitialSendBufferSize: 32
  switchTcpInitialReceiveBufferSize: 64
  switchTcpAutoSendBufferSizeMax: 256
  switchTcpAutoReceiveBufferSizeMax: 256
  switchUdpSendBufferSize: 9
  switchUdpReceiveBufferSize: 42
  switchSocketBufferEfficiency: 4
  switchSocketInitializeEnabled: 1
  switchNetworkInterfaceManagerInitializeEnabled: 1
  switchPlayerConnectionEnabled: 1
  switchUseNewStyleFilepaths: 0
  switchUseLegacyFmodPriorities: 0
  switchUseMicroSleepForYield: 1
  switchEnableRamDiskSupport: 0
  switchMicroSleepForYieldTime: 25
  switchRamDiskSpaceSize: 12
  ps4NPAgeRating: 12
  ps4NPTitleSecret: 
  ps4NPTrophyPackPath: 
  ps4ParentalLevel: 11
  ps4ContentID: ED1633-NPXX51362_00-0000000000000000
  ps4Category: 0
  ps4MasterVersion: 01.00
  ps4AppVersion: 01.00
  ps4AppType: 0
  ps4ParamSfxPath: 
  ps4VideoOutPixelFormat: 0
  ps4VideoOutInitialWidth: 1920
  ps4VideoOutBaseModeInitialWidth: 1920
  ps4VideoOutReprojectionRate: 60
  ps4PronunciationXMLPath: 
  ps4PronunciationSIGPath: 
  ps4BackgroundImagePath: 
  ps4StartupImagePath: 
  ps4StartupImagesFolder: 
  ps4IconImagesFolder: 
  ps4SaveDataImagePath: 
  ps4SdkOverride: 
  ps4BGMPath: 
  ps4ShareFilePath: 
  ps4ShareOverlayImagePath: 
  ps4PrivacyGuardImagePath: 
  ps4ExtraSceSysFile: 
  ps4NPtitleDatPath: 
  ps4RemotePlayKeyAssignment: -1
  ps4RemotePlayKeyMappingDir: 
  ps4PlayTogetherPlayerCount: 0
  ps4EnterButtonAssignment: 1
  ps4ApplicationParam1: 0
  ps4ApplicationParam2: 0
  ps4ApplicationParam3: 0
  ps4ApplicationParam4: 0
  ps4DownloadDataSize: 0
  ps4GarlicHeapSize: 2048
  ps4ProGarlicHeapSize: 2560
  playerPrefsMaxSize: 32768
  ps4Passcode: frAQBc8Wsa1xVPfvJcrgRYwTiizs2trQ
  ps4pnSessions: 1
  ps4pnPresence: 1
  ps4pnFriends: 1
  ps4pnGameCustomData: 1
  playerPrefsSupport: 0
  enableApplicationExit: 0
  resetTempFolder: 1
  restrictedAudioUsageRights: 0
  ps4UseResolutionFallback: 0
  ps4ReprojectionSupport: 0
  ps4UseAudio3dBackend: 0
  ps4UseLowGarlicFragmentationMode: 1
  ps4SocialScreenEnabled: 0
  ps4ScriptOptimizationLevel: 0
  ps4Audio3dVirtualSpeakerCount: 14
  ps4attribCpuUsage: 0
  ps4PatchPkgPath: 
  ps4PatchLatestPkgPath: 
  ps4PatchChangeinfoPath: 
  ps4PatchDayOne: 0
  ps4attribUserManagement: 0
  ps4attribMoveSupport: 0
  ps4attrib3DSupport: 0
  ps4attribShareSupport: 0
  ps4attribExclusiveVR: 0
  ps4disableAutoHideSplash: 0
  ps4videoRecordingFeaturesUsed: 0
  ps4contentSearchFeaturesUsed: 0
  ps4CompatibilityPS5: 0
  ps4AllowPS5Detection: 0
  ps4GPU800MHz: 1
  ps4attribEyeToEyeDistanceSettingVR: 0
  ps4IncludedModules: []
  ps4attribVROutputEnabled: 0
  monoEnv: 
  splashScreenBackgroundSourceLandscape: {{fileID: 0}}
  splashScreenBackgroundSourcePortrait: {{fileID: 0}}
  blurSplashScreenBackground: 1
  spritePackerPolicy: 
  webGLMemorySize: 32
  webGLExceptionSupport: 1
  webGLNameFilesAsHashes: 0
  webGLShowDiagnostics: 0
  webGLDataCaching: 1
  webGLDebugSymbols: 0
  webGLEmscriptenArgs: 
  webGLModulesDirectory: 
  webGLTemplate: APPLICATION:Default
  webGLAnalyzeBuildSize: 0
  webGLUseEmbeddedResources: 0
  webGLCompressionFormat: 0
  webGLWasmArithmeticExceptions: 0
  webGLLinkerTarget: 1
  webGLThreadsSupport: 0
  webGLDecompressionFallback: 0
  webGLInitialMemorySize: 32
  webGLMaximumMemorySize: 2048
  webGLMemoryGrowthMode: 2
  webGLMemoryLinearGrowthStep: 16
  webGLMemoryGeometricGrowthStep: 0.2
  webGLMemoryGeometricGrowthCap: 96
  webGLPowerPreference: 2
  scriptingDefineSymbols: {{}}
  additionalCompilerArguments: {{}}
  platformArchitecture: {{}}
  scriptingBackend: {{}}
  il2cppCompilerConfiguration: {{}}
  il2cppCodeGeneration: {{}}
  managedStrippingLevel: {{}}
  incrementalIl2cppBuild: {{}}
  suppressCommonWarnings: 1
  allowUnsafeCode: 0
  useDeterministicCompilation: 1
  additionalIl2CppArgs: 
  scriptingRuntimeVersion: 1
  gcIncremental: 1
  gcWBarrierValidation: 0
  apiCompatibilityLevelPerPlatform: {{}}
  m_RenderingPath: 1
  m_MobileRenderingPath: 1
  metroPackageName: Glimmerfen
  metroPackageVersion: 
  metroCertificatePath: 
  metroCertificatePassword: 
  metroCertificateSubject: 
  metroCertificateIssuer: 
  metroCertificateNotAfter: 0000000000000000
  metroApplicationDescription: Glimmerfen
  wsaImages: {{}}
  metroTileShortName: 
  metroTileShowName: 0
  metroMediumTileShowName: 0
  metroLargeTileShowName: 0
  metroWideTileShowName: 0
  metroSupportStreamingInstall: 0
  metroLastRequiredScene: 0
  metroDefaultTileSize: 1
  metroTileForegroundText: 2
  metroTileBackgroundColor: {{r: 0.13333334, g: 0.17254902, b: 0.21568628, a: 0}}
  metroSplashScreenBackgroundColor: {{r: 0.12941177, g: 0.17254902, b: 0.21568628, a: 1}}
  metroSplashScreenUseBackgroundColor: 0
  platformCapabilities: {{}}
  metroTargetDeviceFamilies: {{}}
  metroFTAName: 
  metroFTAFileTypes: []
  metroProtocolName: 
  vcxProjDefaultLanguage: 
  XboxOneProductId: 
  XboxOneUpdateKey: 
  XboxOneSandboxId: 
  XboxOneContentId: 
  XboxOneTitleId: 
  XboxOneSCId: 
  XboxOneGameOsOverridePath: 
  XboxOnePackagingOverridePath: 
  XboxOneAppManifestOverridePath: 
  XboxOneVersion: 1.0.0.0
  XboxOnePackageEncryption: 0
  XboxOnePackageUpdateGranularity: 2
  XboxOneDescription: 
  XboxOneLanguage:
  - enus
  XboxOneCapability: []
  XboxOneGameRating: {{}}
  XboxOneIsContentPackage: 0
  XboxOneEnhancedXboxCompatibilityMode: 0
  XboxOneEnableGPUVariability: 1
  XboxOneSockets: {{}}
  XboxOneSplashScreen: {{fileID: 0}}
  XboxOneAllowedProductIds: []
  XboxOnePersistentLocalStorageSize: 0
  XboxOneXTitleMemory: 8
  XboxOneOverrideIdentityName: 
  XboxOneOverrideIdentityPublisher: 
  vrEditorSettings: {{}}
  cloudServicesEnabled: {{}}
  luminIcon:
    m_Name: 
    m_ModelFolderPath: 
    m_PortalFolderPath: 
  luminCert:
    m_CertPath: 
    m_SignPackage: 1
  luminIsChannelApp: 0
  luminVersion:
    m_VersionCode: 1
    m_VersionName: 
  hmiPlayerDataPath: 
  hmiForceSRGBBlit: 1
  embeddedLinuxEnableGamepadInput: 1
  hmiLogStartupTiming: 0
  hmiCpuConfiguration: 
  apiCompatibilityLevel: 6
  activeInputHandler: 0
  windowsGamepadBackendHint: 0
  cloudProjectId: 
  framebufferDepthMemorylessMode: 0
  qualitySettingsNames: []
  projectName: Glimmerfen
  organizationId: 
  cloudEnabled: 0
  legacyClampBlendShapeWeights: 0
  hmiLoadingImage: {{fileID: 0}}
  platformRequiresReadableAssets: 0
  virtualTexturingSupportEnabled: 0
  insecureHttpOption: 0
""")
    write(ROOT / "ProjectSettings/EditorBuildSettings.asset", f"""%YAML 1.1
%TAG !u! tag:unity3d.com,2011:
--- !u!1045 &1
EditorBuildSettings:
  m_ObjectHideFlags: 0
  serializedVersion: 2
  m_Scenes:
  - enabled: 1
    path: Assets/Scenes/Main.unity
    guid: {SCENE_GUID}
  m_configObjects: {{}}
""")
    write(ROOT / "Packages/manifest.json", json.dumps({
        "dependencies": {
            "com.unity.modules.ai": "1.0.0",
            "com.unity.modules.animation": "1.0.0",
            "com.unity.modules.audio": "1.0.0",
            "com.unity.modules.imageconversion": "1.0.0",
            "com.unity.modules.imgui": "1.0.0",
            "com.unity.modules.jsonserialize": "1.0.0",
            "com.unity.modules.physics2d": "1.0.0",
            "com.unity.modules.ui": "1.0.0",
            "com.unity.modules.uielements": "1.0.0",
        }
    }, indent=2) + "\n")
    write(ROOT / "Assets/Scenes/Main.unity", SCENE)
    write(ROOT / "Assets/Scenes/Main.unity.meta", f"""fileFormatVersion: 2
guid: {SCENE_GUID}
DefaultImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
""")
    write(ROOT / "Assets/Scripts/FloeStarter.cs", CS_SOURCE)
    write(ROOT / "Assets/Scripts/FloeStarter.cs.meta", f"""fileFormatVersion: 2
guid: {SCRIPT_GUID}
MonoImporter:
  externalObjects: {{}}
  serializedVersion: 2
  defaultReferences: []
  executionOrder: 0
  icon: {{instanceID: 0}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
""")
    write(ROOT / "Assets/Editor/FloeWebBuild.cs", EDITOR_SOURCE)
    write(ROOT / "Assets/Editor/FloeWebBuild.cs.meta", f"""fileFormatVersion: 2
guid: {EDITOR_GUID}
MonoImporter:
  externalObjects: {{}}
  serializedVersion: 2
  defaultReferences: []
  executionOrder: 0
  icon: {{instanceID: 0}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
""")
    for folder, guid in [("Assets/Scenes", "3c4d5e6f7a8b49c0d1e2f3a4b5c6d7e8"),
                         ("Assets/Scripts", "4d5e6f7a8b9c40d1e2f3a4b5c6d7e8f9"),
                         ("Assets/Editor", "5e6f7a8b9c0d41e2f3a4b5c6d7e8f9a0")]:
        write(ROOT / (folder + ".meta"), f"""fileFormatVersion: 2
guid: {guid}
folderAsset: yes
DefaultImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
""")
    write(ROOT / "floe-inputs.json", json.dumps({
        "schemaVersion": 1, "engine": "unity",
        "movement": {"left": ["left"], "right": ["right"], "up": ["up"], "down": ["down"]},
        "buttons": [
            {"id": "confirm", "label": "Z (also Enter/Space)", "keys": ["z"]},
            {"id": "cancel", "label": "X (also Esc)", "keys": ["x"]},
            {"id": "pageLeft", "label": "Q", "keys": ["q"]},
            {"id": "pageRight", "label": "W", "keys": ["w"]},
            {"id": "save", "label": "F5", "keys": ["f5"]},
            {"id": "load", "label": "F9", "keys": ["f9"]},
        ],
    }, indent=2, ensure_ascii=False) + "\n")
    write(ROOT / "README.md", f"""# Glimmerfen (Unity)

Original Floe starter project for Unity {UNITY_VERSION} LTS. It contains
original C# source, a minimal standard scene, versioned project metadata and an
Editor WebGL build bootstrap. It bundles no Unity engine code, third-party
assets, packages or prebuilt WebGL output.

## Prerequisites

- Unity {UNITY_VERSION} LTS (exact pinned editor version).
- WebGL Build Support for that editor if you want to build.

Open the project in the pinned Unity Editor, play `Assets/Scenes/Main.unity`, or
run `Floe > Build WebGL` / `FloeWebBuild.BuildFromCommandLine()`. No Unity or
WebGL build was executed by this fixture generator. The original C# source,
scene and metadata are MIT-licensed; Unity and imported assets retain their own
terms.
""")
    write(ROOT / "licenses/FLOE-STARTER-MIT.txt", MIT_TEXT)
    write(ROOT / "licenses/ENGINE-NOTES.md",
          "# Engine prerequisite\n\n"
          f"This project targets Unity {UNITY_VERSION} LTS. It does not include the Unity\n"
          "Editor, engine binaries, packages or a prebuilt WebGL player. The user must\n"
          "install the pinned editor and WebGL Build Support. The original Floe C#\n"
          "source, scene and metadata are MIT-licensed; Unity and any imported assets\n"
          "retain their own terms.\n")
    files = []
    for path in sorted(ROOT.rglob("*")):
        if path.is_file():
            blob = path.read_bytes()
            files.append({"path": path.relative_to(ROOT).as_posix(),
                          "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob)})
            if path.suffix == ".json":
                json.loads(blob.decode("utf-8"))
    assert "m_EditorVersion: " + UNITY_VERSION in (ROOT / "ProjectSettings/ProjectVersion.txt").read_text()
    assert "RuntimeInitializeOnLoadMethod" in (ROOT / "Assets/Scripts/FloeStarter.cs").read_text()
    assert "BuildTarget.WebGL" in (ROOT / "Assets/Editor/FloeWebBuild.cs").read_text()
    return {"engine": NAME, "root": str(ROOT), "files": len(files),
            "bytes": sum(x["bytes"] for x in files), "manifest": files}


if __name__ == "__main__":
    print(json.dumps({"starter": generate()}, indent=2, ensure_ascii=False))
