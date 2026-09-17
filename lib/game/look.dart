/// 卡比风格的外观预设。
///
/// 直接落地 flutter_scene `looks` skill 的核心结论：**好看是光照 + 后处理决定的，
/// 不是几何**。它给了四套现成预设，这里取 `stylized` 的思路——鲜艳、微暖、发光、
/// 平面化（不上重遮蔽和屏幕空间反射）——正好匹配卡比的卡通调性；
/// 再叠一层随天气走的雾与曝光，让天气切换有真实的空气感。
///
/// 由世界侧通过 `scene.baseEnvironment = ...` 下发（引擎会在内部把整条后处理栈
/// 的应用逻辑跑完，不需要逐个去设 `scene.fog` / `scene.postProcess`）。
/// **用 `baseEnvironment` 而非 `environmentSettings`** 是因为河谷雾体积
/// （`Scene.environmentVolumes`）要靠它做相机位置混合——base 为 null 时
/// 引擎会把整张体积列表忽略掉。

library;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// 构造一套完整外观。[fogDensity] / [exposure] / [fogSkyColorInfluence]
/// 三个量由天气系统驱动（其余是固定的卡比风格底）。
EnvironmentSettings buildKirbyLook({
  required double fogDensity,
  required double exposure,
  required double environmentIntensity,
  vm.Vector3? fogColor,
  double fogSkyColorInfluence = 0.0,
  Skybox? skybox,
}) {
  return EnvironmentSettings(
    // **必须带上天空盒**：`EnvironmentSettings.applyTo` 是
    // `scene.skybox = skybox` 的无条件赋值，传 null 会把天空清成纯黑。
    skybox: skybox,
    toneMapping: ToneMappingMode.aces,
    exposure: exposure,

    // 环境光由天气系统驱动（白天 0.60 / 夜晚 0.12）：
    // IBL 是"四面八方都在发光"，强度一高植被暗部被抬平、失去体积；
    // 而夜晚若不跟着压下来，整个场景会被照成白天亮度（实测教训）。
    environmentIntensity: environmentIntensity,

    // 色彩：饱和度与暖度拉高，卡通感的主要来源。
    colorGradingEnabled: true,
    saturation: 1.22,
    contrast: 1.16,
    brightness: 0.98,
    temperature: 0.08,

    // 泛光：给收集物的发光核与卡比的腮红做辉光。
    bloomEnabled: true,
    bloomThreshold: 0.95,
    bloomIntensity: 0.26,
    bloomScatter: 0.78,

    // 环境光遮蔽：半分辨率，只用来给草地/石头"落地"，不做重遮蔽。
    ambientOcclusionEnabled: true,
    ambientOcclusionMethod: AmbientOcclusionMethod.obscurance,
    ambientOcclusionIntensity: 0.7,
    ambientOcclusionPower: 1.5,
    ambientOcclusionRadius: 1.2,
    ambientOcclusionHalfResolution: true,

    // 雾：天气系统的主要可见载体之一（雨天更浓、更灰）。
    fogEnabled: true,
    fogMode: FogMode.exponential,
    fogColor: fogColor ?? vm.Vector3(0.74, 0.82, 0.90),
    fogDensity: fogDensity,
    // 空气透视：雾色里有多少取自**视线方向上的天光**。
    // 0 = 一片平涂的灰（远处山脊像剪纸），1 = 完全褪进天空。
    // 取值在天气系统侧按昼夜缩放（夜里必须收小，见 [SkySystem.fogSkyColorInfluence]）。
    // 注意只对受光材质生效：unlit 材质（云/雨丝/星星）一律用平涂 [fogColor]。
    fogSkyColorInfluence: fogSkyColorInfluence,
    // **cutoff 是"蓝天保卫战"的关键**：雾按相机距离洗一切几何，
    // 240m 的天穹会被雾洗成灰白、蓝天全灭（实测）。
    // cutoff 200 = 200m 外（天穹/星月）不再参与雾，地形（≤150m）照常。
    fogCutoffDistance: 200.0,
    // 上限 0.85：即使雾很浓，天空也能透出一点，不会变成死灰色。
    fogMaxOpacity: 0.85,
    // 贴地雾：雾随海拔升高变薄（exponential 模式专属）——
    // 谷底浓、山顶清，"晨雾贴地"的观感就靠它。
    fogHeightFalloff: 0.12,
    // 太阳逆散射：朝太阳看时雾里透出光晕——没有体积雾时的廉价替代。
    fogSunInScatter: 0.25,

    vignetteEnabled: true,
    vignetteIntensity: 0.18,
  );
}
