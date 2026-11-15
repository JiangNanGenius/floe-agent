// SPDX-License-Identifier: MPL-2.0
// Unity WebGL push bridge. Place in Assets/Scripts/. Call RegisterDefault()
// once and Publish/ApplyPending from your game loop; no reflection is used.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;
using UnityEngine.SceneManagement;

public static class FloeDeveloperBridge
{
#if UNITY_WEBGL && !UNITY_EDITOR
    [DllImport("__Internal")] private static extern int FloeDeveloperAvailable();
    [DllImport("__Internal")] private static extern void FloeDeveloperRegister(string json);
    [DllImport("__Internal")] private static extern void FloeDeveloperPublish(string json);
    [DllImport("__Internal")] private static extern IntPtr FloeDeveloperTakeCommands();
    [DllImport("__Internal")] private static extern void FloeDeveloperAck(int id, int ok);
    [DllImport("__Internal")] private static extern void FloeDeveloperFree(IntPtr pointer);
#endif

    [Serializable] private sealed class CommandEnvelope { public List<Command> items = new List<Command>(); }
    [Serializable] private sealed class Command
    {
        public int id;
        public string kind = "";
        public string field = "";
        public string action = "";
        public float value;
    }
    [Serializable] private sealed class PublishState
    {
        public string scene_name;
        public bool paused;
        public float time_scale;
        public int frames;
    }

    public static bool HostAvailable
    {
        get
        {
#if UNITY_WEBGL && !UNITY_EDITOR
            return FloeDeveloperAvailable() == 1;
#else
            return false;
#endif
        }
    }

    public static bool Enabled { get; private set; }
    public static bool Registered { get; private set; }

    public static void RegisterDefault()
    {
#if UNITY_WEBGL && !UNITY_EDITOR
        if (Registered || !HostAvailable) return;
        string descriptor = "{" +
            "\"runtime\":\"Unity WebGL\"," +
            "\"fields\":[" +
              "{\"id\":\"scene.name\",\"label\":\"Scene\",\"labelZhHans\":\"场景\",\"group\":\"Unity\",\"groupZhHans\":\"Unity\",\"kind\":\"readOnlyText\",\"symbol\":\"square.stack\"}," +
              "{\"id\":\"engine.paused\",\"label\":\"Paused\",\"labelZhHans\":\"已暂停\",\"group\":\"Unity\",\"groupZhHans\":\"Unity\",\"kind\":\"readOnlyBoolean\",\"symbol\":\"pause\"}," +
              "{\"id\":\"engine.timescale\",\"label\":\"Time scale\",\"labelZhHans\":\"时间缩放\",\"group\":\"Unity\",\"groupZhHans\":\"Unity\",\"kind\":\"number\",\"symbol\":\"gauge.with.dots.needle.67percent\",\"minimum\":0,\"maximum\":4,\"step\":0.05}," +
              "{\"id\":\"engine.frames\",\"label\":\"Frames\",\"labelZhHans\":\"帧数\",\"group\":\"Unity\",\"groupZhHans\":\"Unity\",\"kind\":\"readOnlyNumber\",\"symbol\":\"film\"}" +
            "]," +
            "\"actions\":[" +
              "{\"id\":\"engine.pause\",\"label\":\"Pause\",\"labelZhHans\":\"暂停\",\"group\":\"Unity\",\"groupZhHans\":\"Unity\",\"symbol\":\"pause.fill\",\"isQuick\":true}," +
              "{\"id\":\"engine.resume\",\"label\":\"Resume\",\"labelZhHans\":\"继续\",\"group\":\"Unity\",\"groupZhHans\":\"Unity\",\"symbol\":\"play.fill\",\"isQuick\":true}" +
            "]}";
        FloeDeveloperRegister(descriptor);
        Enabled = true;
        Registered = true;
#endif
    }

    public static void Publish()
    {
#if UNITY_WEBGL && !UNITY_EDITOR
        if (!Enabled) return;
        var state = new PublishState
        {
            scene_name = SceneManager.GetActiveScene().name,
            paused = Time.timeScale <= 0.0001f,
            time_scale = Time.timeScale,
            frames = Time.frameCount
        };
        FloeDeveloperPublish(JsonUtility.ToJson(state));
#endif
    }

    public static void ApplyPending()
    {
#if UNITY_WEBGL && !UNITY_EDITOR
        if (!Enabled) return;
        IntPtr pointer = FloeDeveloperTakeCommands();
        if (pointer == IntPtr.Zero) return;
        try
        {
            var envelope = JsonUtility.FromJson<CommandEnvelope>(ReadString(pointer));
            if (envelope == null || envelope.items == null) return;
            foreach (var command in envelope.items)
            {
                bool applied = false;
                if (command.kind == "set" && command.field == "engine.timescale")
                {
                    Time.timeScale = Mathf.Clamp(command.value, 0f, 4f);
                    applied = true;
                }
                else if (command.kind == "action" && command.action == "engine.pause")
                {
                    Time.timeScale = 0f;
                    applied = true;
                }
                else if (command.kind == "action" && command.action == "engine.resume")
                {
                    Time.timeScale = 1f;
                    applied = true;
                }
                FloeDeveloperAck(command.id, applied ? 1 : 0);
            }
        }
        finally
        {
            FloeDeveloperFree(pointer);
        }
#endif
    }

    private static string ReadString(IntPtr pointer)
    {
        int length = 0;
        while (Marshal.ReadByte(pointer, length) != 0) length++;
        var bytes = new byte[length];
        Marshal.Copy(pointer, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }
}
