// SPDX-License-Identifier: MPL-2.0
// Unity WebGL automatic bridge loop. The file/class name match so Unity can
// attach this component; FloeDeveloperBridge holds the static jslib bindings.
using UnityEngine;

#if UNITY_WEBGL && !UNITY_EDITOR
[DefaultExecutionOrder(10000)]
public sealed class FloeDeveloperBridgeBehaviour : MonoBehaviour
{
    private static FloeDeveloperBridgeBehaviour instance;

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void Install()
    {
        if (instance != null || !FloeDeveloperBridge.HostAvailable) return;
        var go = new GameObject("FloeDeveloperBridge");
        DontDestroyOnLoad(go);
        instance = go.AddComponent<FloeDeveloperBridgeBehaviour>();
    }

    private void Awake()
    {
        if (instance != null && instance != this)
        {
            Destroy(gameObject);
            return;
        }
        instance = this;
        FloeDeveloperBridge.RegisterDefault();
    }

    private void Update()
    {
        FloeDeveloperBridge.Publish();
        FloeDeveloperBridge.ApplyPending();
    }
}
#endif
