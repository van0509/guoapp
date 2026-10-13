const allSourcesEnabled = bool.fromEnvironment('ALL_SOURCES');
const android6Compatibility = bool.fromEnvironment('ANDROID6_COMPAT');
const liveActivationCode = 'van0509';
const _compatibilitySuffix = android6Compatibility ? '兼容版' : '';
const appName = (allSourcesEnabled ? '真果鉴' : '红果鉴') + _compatibilitySuffix;
const appSlug = allSourcesEnabled ? 'zhenguojian' : 'hongguojian';

/// 全站源版可在完整模式与绿色模式之间切换，默认保持完整模式。
String appEditionName(bool fullMode) =>
    (allSourcesEnabled && fullMode ? '真果鉴' : '红果鉴') + _compatibilitySuffix;
