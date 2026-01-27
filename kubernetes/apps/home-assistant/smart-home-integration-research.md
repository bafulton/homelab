# Smart Home Integration Research

Research on syncing Home Assistant devices and scenes to Apple Home and Google Home.

## Google Home Integration

There's a direct equivalent to HomeKit Bridge for Google:

1. **[Google Assistant Integration](https://www.home-assistant.io/integrations/google_assistant/)** - Exposes HA entities to Google Home
2. **Easiest setup**: Via [Nabu Casa](https://www.nabucasa.com/config/google_assistant/) (paid Home Assistant Cloud) - just enable and link in Google Home app
3. **Self-hosted**: Requires setting up an Actions on Google project (more complex, and Google recently migrated to a new Developer Console which broke some setups)

## The Scene Problem

This is where it gets frustrating:

- **HomeKit**: HA scenes are exposed as **buttons, not actual scenes** ([GitHub issue #124379](https://github.com/home-assistant/core/issues/124379)). Philips Hue can do proper scene sync, but HA can't yet.
- **Google Home**: Similar limitation - no native scene sync from HA
- **Workaround**: [Stateful Scenes](https://github.com/hugobloem/stateful_scenes) custom integration creates switches that infer scene state, which you can then manually create as scenes in each ecosystem

**Reality**: You'll likely still need to maintain scenes separately in each ecosystem, or accept using HA as the single automation engine and just expose individual devices.

## Matter Bridge - The Unified Approach

This might be the best path forward:

**[Home-Assistant-Matter-Hub](https://t0bst4r.github.io/home-assistant-matter-hub/)** is a third-party add-on that exposes HA entities as Matter devices. Both Apple Home and Google Home can then control them via Matter's local protocol.

Benefits:
- Single bridge to both ecosystems
- Local communication (no cloud dependency)
- No port forwarding needed

Limitations:
- Still doesn't solve the scene problem
- Google Home requires a Google Hub for Matter pairing
- Device limits (~80-100 for some controllers)

## The Duplicate Device Problem

When devices are natively supported by multiple ecosystems (e.g., TP-Link in Google Home, HomeKit-native devices in Apple Home), there are two strategies:

| Strategy | Pros | Cons |
|----------|------|------|
| **HA as single source** | One place to manage everything, consistent state | Lose native ecosystem features, latency |
| **Native + HA selective bridging** | Best performance per ecosystem | Duplicates, state sync issues |

**Recommendation**: Use native integrations where they work well (Thread/Matter devices in Apple Home, etc.), and only bridge devices through HA that aren't supported natively. Keep automations in HA but accept that scenes will be duplicated.

## Summary

- **Google Home sync**: Yes, via Google Assistant integration (Nabu Casa is easiest)
- **Scene sync**: Not really supported properly in either ecosystem - duplicates are unavoidable
- **Consider Matter Bridge**: Cleaner than maintaining both HomeKit Bridge + Google Assistant integration
- **Accept the tradeoff**: Either commit to HA as the single automation brain, or accept some duplication

## Sources

- [Google Assistant Integration](https://www.home-assistant.io/integrations/google_assistant/)
- [Nabu Casa Google Assistant](https://www.nabucasa.com/config/google_assistant/)
- [HomeKit Bridge](https://www.home-assistant.io/integrations/homekit/)
- [Scene sync issue](https://github.com/home-assistant/core/issues/124379)
- [Stateful Scenes](https://github.com/hugobloem/stateful_scenes)
- [Home-Assistant-Matter-Hub](https://t0bst4r.github.io/home-assistant-matter-hub/)
- [MatterBridge overview](https://thissmart.house/2025/11/26/matterbridge-for-home-assistant-expose-any-device-to-matter-controllers/)
