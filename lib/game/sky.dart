/// 天空系统 v5：引擎天空盒 + 三层动态云 + 河谷雾体积 + 分层夜空
/// （星空/银河/月晕/流星）+ 强化降雨（雨幕/水花/积水/涟漪/闪电）。
///
/// ## 天空盒：用引擎的 `Skybox`，不再手搓渐变穹顶
///
/// 旧版是顶点色渐变球，问题有二：会被雾洗（400m 处 47% 雾化）、
/// 天色只能靠染色乘子近似。现在改用引擎的天空盒槽位 `Scene.skybox`：
///   * 由引擎在**一切几何之后整屏绘制**——不受距离雾影响
///     （`Fog` 文档明确 "skybox is left unfogged"）、不占几何、不占 draw call；
///   * 自带 HDR 太阳盘（亮度 > 1，正好吃 bloom），颜色由天气的光照折算；
///   * 天顶 / 地平线 / 地面三色由天气驱动（浑浊度去饱和 + 夜色压暗）。
///
/// **用 `GradientSkySource` 而不是 `PhysicalSkySource`**：本机
/// （Impeller/Metal、flutter_scene 0.23.0）解析式大气散射那个源整片渲染成
/// **纯黑**（场景正常、天空全黑、日志无报错），换成渐变源立刻正常 ——
/// 所以走渐变方案，天色靠三色 + "浑浊度去饱和"手工逼近。
///
/// ## 云：三层程序化云，整层旋转即"漂移"
///
/// 高层卷云（拉得很扁、漂得最慢）/ 中层积云 / 低层层积云（成团、漂得最快）
/// 三层速度各不相同 → 视差（只堆一层怎么调都像贴纸）；
/// 每层是一张 InstancedMesh，漂移只写节点旋转（每帧三个四元数），
/// 实例矩阵完全不动——零重打包开销。
/// 云团外观由三件事叠出来：云泡几何的**顶点色顶亮底暗**（体积感）、
/// 实例色的**迎光面暖 / 背光面冷**（日照方向）、以及**逐团出现阈值**
/// （云量决定"多少朵云"，而不是"整层变淡"）。
///
/// 云环的**半径**与相机取景是一对约束：云的仰角 `atan(y / r)` 必须落在
/// 画面实际覆盖的仰角带里（fov 60°、默认俯角 5.7° → 地平线上方 0~24.3°）。
/// 半径铺得够宽（rMax 320/253/190，仰角下限 11°/9.4°/8.4°）才能铺满整条带；
/// 而半径一大，云泡的角尺寸就会缩，所以云泡尺寸按 `r / rBase` **等比放大**，
/// 保证"铺多宽都是一样大的云"。早期半径只到 105/86/62，结果是全部云团
/// 挤在画面上缘 5% 里、下面 20° 一片空渐变（默认视角实测 9~21° 完全无云）。
///
/// ## 体积雾：引擎的 `EnvironmentVolume`
///
/// 河谷走廊放一个 Box 体积，相机进入时雾变浓（Unity Volume 模型，
/// blendDistance 平滑过渡）。**前提是 `Scene.baseEnvironment` 必须被设置**：
/// 引擎的 `_applyEnvironmentVolumes` 在 base 为 null 时直接 return，
/// 此时 `environmentVolumes` 会被**整个忽略**（这不是"体积没生效"，
/// 是连混合都没跑）。所以世界侧下发外观走 `baseEnvironment` 而非
/// `environmentSettings`。体积的曝光/环境光/密度**同步当前天气**，
/// 否则它会拿构建时的静态值对抗天气过渡（切天气时河谷里会跳变）。
///
/// **体积的 settings 必须用同一个 [buildKirbyLook] 造、只覆写雾**：
/// 引擎混合 base 与体积是 `EnvironmentSettings.lerp(base, volume, w)` 的
/// **逐字段**插值，体积里没写的字段会被拉向**构造默认值**（不是"保持不动"）。
/// 只写 skybox + 几项雾时，泛光/色彩分级/AO/暗角/雾 cutoff 全被拉回默认，
/// 进谷整屏洗成一片亮蓝（实测夜景谷内均值 46.5 vs 谷外 28.7）。
///
/// ## 夜晚与降雨
///
/// 夜晚 = `nightAmount` 压暗天空盒三色（天顶 10%、偏蓝）+ 星空实例 +
/// 月亮（HDR 亮度吃 bloom）+ 月光平行光。
///
/// 夜空的"层次"由四层叠出来，单有星星会显得很平：
///   1. **背景星**：星等幂律（多数暗、少数亮）+ 噪声疏密斑块；
///   2. **银河带**：银道面附近加密的暗星 + 一条顶点色渐变的弥散光带；
///   3. **月亮**：HDR 月面 + 幂律尺寸的月海 + 朝向相机的月晕 billboard；
///   4. **流星**：偶发划过，给静态星空一个"活"的瞬时事件。
/// 星星用双频闪烁（主频眨眼 + 慢频调制幅度），整片星空不会齐步闪。
///
/// 降雨 = 2200 雨丝 + 水花池 + 积水盘 + 积水涟漪 + 低频闪电。
/// 雨丝的斜度/丝长随阵风呼吸，X/Z 双向环绕回收保证雨幕始终跟着玩家。
/// `nightAmount` / `rainAmount` 两个 0-1 标量驱动各自元素的渐显渐隐。
library;
import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'look.dart';
import 'noise.dart';
import 'terrain.dart';

enum WeatherKind {
  clear('晴朗'),
  cloudy('多云'),
  rain('降雨'),
  night('夜晚');

  const WeatherKind(this.label);
  final String label;
}

/// 一种天气的完整参数集。切天气 = 在两组参数之间插值，而不是逐项改代码。
class WeatherProfile {
  const WeatherProfile({
    required this.skyTint,
    required this.sunIntensity,
    required this.sunToward,
    required this.lightTravel,
    required this.lightColor,
    required this.skyTurbidity,
    required this.skyMie,
    required this.skyEnergy,
    required this.cloudColor,
    required this.cloudCoverage,
    required this.valleyMist,
    required this.lensFlare,
    required this.fogDensity,
    required this.exposure,
    required this.environmentIntensity,
    required this.rainAmount,
    required this.nightAmount,
    required this.grassWind,
  });

  /// 氛围染色：主要供雾色使用（雨灰、夜蓝）。
  final vm.Vector4 skyTint;
  final double sunIntensity;

  /// **朝向太阳**的方向（驱动物理天空盒：太阳仰角决定昼夜与天色）。
  /// 夜晚时太阳在地平线下（y 为负）→ 物理天空自然给出暮色后的深蓝。
  final vm.Vector3 sunToward;

  /// 平行光的**行进方向**（与 sunToward 解耦）：
  /// 夜晚光源是月亮（在天上），而可见天空的太阳必须在地平线下 ——
  /// 一个参数表达不了这对矛盾，所以拆开。
  final vm.Vector3 lightTravel;

  /// 平行光颜色：白天暖白、雨天冷灰、夜晚偏蓝月光。
  final vm.Vector3 lightColor;

  /// 物理天空盒的大气浑浊度（雾霭）：晴 2.6 → 雨 14。
  final double skyTurbidity;

  /// 米氏散射系数（太阳周围的雾晕）。
  final double skyMie;

  /// 物理天空盒整体亮度。
  final double skyEnergy;

  /// 云的颜色（实例材质染色）。
  final vm.Vector3 cloudColor;

  /// 云量 0–1：同时驱动云的不透明度。
  final double cloudCoverage;

  /// 河谷雾体积的权重 0–1：雨夜最浓，晴天只是薄薄一层谷气。
  final double valleyMist;

  /// 是否启用镜头光晕（只有晴天看得见太阳时才有意义）。
  final bool lensFlare;

  final double fogDensity;
  final double exposure;

  /// 环境光（IBL）强度。**必须随昼夜变化**：IBL 是"四面八方的天光"，
  /// 不受太阳强度控制 —— 夜晚若保持白天的 0.60，整个场景会被照成
  /// 白天亮度，星空/月光全部白搭（实测教训）。夜晚压到 0.24。
  final double environmentIntensity;

  /// 0 = 无雨，1 = 满强度雨幕。
  final double rainAmount;

  /// 0 = 白昼，1 = 深夜。星空/月亮/月光的可见度都由它驱动。
  final double nightAmount;

  /// 风力强度，供草地风摆使用。
  final double grassWind;

  /// 月光方向 = 月光的行进方向（y 为负、朝下）。
  /// **月亮的可视位置在它的反方向上**——直接拿光照方向当位置，
  /// 月亮会被埋进地底（实测踩过）。
  ///
  /// 仰角压到 **12°**（方位 28.7°），原先是 33.5°。原因：相机 `fovRadiansY`
  /// 只有 45°（半视场 22.5°）、默认俯角 17.2° → 画面里的天空只有地平线上方
  /// **5.3°**；即使把相机仰到极限（此时贴地保护把视线上限顶到 26.3°），
  /// 也看不到 33.5° 的月亮 —— **月亮恒定在画外，等于不存在**
  /// （实测：朝月亮方位仰到极限截图，峰值亮度 213、极亮像素 0.00%，无任何亮斑）。
  /// 配合 `buildCamera` 把 fov 提到 60° 后，默认视角上缘到 12.8°，月亮才真正入画。
  static final vm.Vector3 moonDirection =
      vm.Vector3(-0.470, -0.208, -0.858).normalized();

  static final Map<WeatherKind, WeatherProfile> presets = {
    WeatherKind.clear: WeatherProfile(
      skyTint: vm.Vector4(0.95, 1.00, 1.00, 1.0),
      sunIntensity: 3.4,
      sunToward: vm.Vector3(0.45, 0.70, 0.35),
      lightTravel: vm.Vector3(-0.45, -0.70, -0.35),
      lightColor: vm.Vector3(1.00, 0.96, 0.88),
      skyTurbidity: 2.6,
      skyMie: 0.0045,
      skyEnergy: 1.0,
      cloudColor: vm.Vector3(0.97, 0.98, 1.00),
      cloudCoverage: 0.55,
      valleyMist: 0.45,
      lensFlare: true,
      // 晴天也要一点薄雾：完全没有雾时远处地形是"剪纸贴在山脚"，
      // 有 0.003 这一档，山脊才会随距离轻微褪色、读出纵深。
      fogDensity: 0.0035,
      exposure: 1.0,
      environmentIntensity: 0.60,
      rainAmount: 0.0,
      nightAmount: 0.0,
      grassWind: 0.18,
    ),
    WeatherKind.cloudy: WeatherProfile(
      skyTint: vm.Vector4(0.80, 0.84, 0.90, 1.0),
      sunIntensity: 1.5,
      sunToward: vm.Vector3(0.30, 0.55, 0.55),
      lightTravel: vm.Vector3(-0.30, -0.55, -0.55),
      lightColor: vm.Vector3(0.90, 0.92, 1.00),
      skyTurbidity: 7.0,
      skyMie: 0.011,
      skyEnergy: 0.62,
      cloudColor: vm.Vector3(0.80, 0.84, 0.90),
      cloudCoverage: 0.85,
      valleyMist: 0.70,
      lensFlare: false,
      fogDensity: 0.0060,
      exposure: 0.95,
      environmentIntensity: 0.55,
      rainAmount: 0.0,
      nightAmount: 0.0,
      grassWind: 0.30,
    ),
    WeatherKind.rain: WeatherProfile(
      // 雨天的"压抑感"来自三个量的组合，缺一不可：
      //   1) 浑浊度拉满（14）→ 天光从蓝变成铅灰；
      //   2) 曝光/环境光一起压低 → 暗部沉下去，雨幕的白丝才有对比；
      //   3) 雾更浓且偏冷灰 → 远处地形褪成剪影，
      //      把"近处雨丝密、远处一片灰"的纵深读出来（只有雨丝没有雾
      //      会像贴了一层贴纸，实测）。
      skyTint: vm.Vector4(0.48, 0.53, 0.62, 1.0),
      sunIntensity: 0.62,
      sunToward: vm.Vector3(0.20, 0.45, 0.70),
      lightTravel: vm.Vector3(-0.20, -0.45, -0.70),
      lightColor: vm.Vector3(0.72, 0.78, 0.94),
      skyTurbidity: 14.0,
      skyMie: 0.021,
      skyEnergy: 0.30,
      cloudColor: vm.Vector3(0.36, 0.41, 0.50),
      cloudCoverage: 1.0,
      valleyMist: 1.0,
      lensFlare: false,
      fogDensity: 0.0170,
      exposure: 0.85,
      environmentIntensity: 0.44,
      rainAmount: 1.0,
      nightAmount: 0.0,
      grassWind: 0.52,
    ),
    WeatherKind.night: WeatherProfile(
      // 夜晚：夜色由 nightAmount 压暗天空盒三色 + 星空/月亮叠加而来；
      // 月亮挂在 12° 仰角（见 [moonDirection]），月光（lightTravel）从它照下来。
      skyTint: vm.Vector4(0.09, 0.11, 0.26, 1.0),
      // 月光本身比太阳弱得多（0.52 vs 3.4），但偏蓝且干净 ——
      // 蓝色在暗场里最容易被眼睛读成"夜"，比单纯压亮度有效。
      sunIntensity: 0.55,
      sunToward: vm.Vector3(-0.46, -0.30, 0.65),
      lightTravel: vm.Vector3(0.40, -0.55, -0.73),
      lightColor: vm.Vector3(0.58, 0.70, 1.00),
      skyTurbidity: 3.2,
      skyMie: 0.006,
      skyEnergy: 1.0,
      cloudColor: vm.Vector3(0.14, 0.17, 0.28),
      cloudCoverage: 0.55,
      valleyMist: 0.60,
      lensFlare: false,
      // 夜晚雾比白天略浓且偏蓝：给星空/月亮垫一层空气，
      // 也让远处地形褪进夜色里（否则星星挂在"纯黑幕布"上，没有纵深）。
      fogDensity: 0.0016,
      exposure: 0.80,
      // 环境光再压低一点（0.24 → 0.22）：IBL 是四面八方的天光，
      // 只要它亮着，星星与月光的对比度就被稀释。
      environmentIntensity: 0.22,
      rainAmount: 0.0,
      nightAmount: 1.0,
      grassWind: 0.12,
    ),
  };
}

/// 天空 + 云 + 谷雾体积 + 星月 + 雨幕 + 水花/积水 + 天气过渡。
class SkySystem {
  SkySystem({required this.terrain, int seed = 404})
      : _rng = math.Random(seed),
        _noise = ValueNoise(seed: seed ^ 0x51ce),
        _sunLight = DirectionalLight(
          direction: WeatherProfile.presets[WeatherKind.clear]!.lightTravel,
          color: WeatherProfile.presets[WeatherKind.clear]!.lightColor,
          intensity: WeatherProfile.presets[WeatherKind.clear]!.sunIntensity,
          // 阴影是立体感的最大来源；若某个后端不支持，引擎会自行降级。
          castsShadow: true,
        );

  final Terrain terrain;
  final math.Random _rng;
  final ValueNoise _noise;
  final DirectionalLight _sunLight;

  /// 云层与夜空所在的"天穹半径"（米）。
  ///
  /// 天空盒本身不需要它，但云 / 星 / 月亮都按这个半径为基准摆放：
  /// 太远会被距离雾洗成灰片，太近则抬头就穿出云底。
  static const double domeRadius = 240.0;

  /// ---- 引擎天空盒（`GradientSkySource`）----
  ///
  /// 挂在 `Scene.skybox` 槽位上，由引擎在一切几何之后**整屏**绘制：
  /// 不受距离雾影响（`Fog` 文档明确 "skybox is left unfogged"）、
  /// 不占几何、不占 draw call。天色 = 天顶/地平线/地面三色 + 一个
  /// HDR 太阳盘（亮度 > 1，正好吃 bloom），四个量全部由天气驱动。
  ///
  /// **为何不用 `PhysicalSkySource`**：本机（Impeller/Metal、
  /// flutter_scene 0.23.0）解析式大气那个片元着色器整片渲染成黑
  /// （场景正常、天空纯黑，日志无报错），而换成 `GradientSkySource`
  /// 立刻正常 —— 所以走渐变方案，天色靠三色 + 浑浊度去饱和手工调。
  late final GradientSkySource _skySource;

  /// 天空盒本体。**必须由世界侧写进 `EnvironmentSettings.skybox`**。
  ///
  /// 坑（实测）：`EnvironmentSettings` 里带 `skybox` 字段，而 `applyTo` 是
  /// `scene.skybox = skybox` **无条件赋值** —— 只要任何一次下发外观时它的
  /// skybox 是 null，`scene.skybox` 就被清成 null，**整个天空变纯黑**
  /// （地形/云/雨都正常，只有天是黑的，日志无任何报错）。
  /// 更阴的是：河谷雾体积一旦启用，引擎**每帧**都会用
  /// `base + 体积` 重新 apply 一次，所以 base 与体积的 settings 两边
  /// 都必须带上天空盒，否则谷内/谷外必有一边黑。
  late final Skybox _skybox;

  /// 天空盒三色基准（晴天：天顶 / 地平线 / 地面）。
  /// 浑浊度会把它们一起去饱和、夜色再整体压暗，
  /// 所以三个基准色就足以覆盖晴 / 阴 / 雨 / 夜四种气氛。
  static final vm.Vector3 _skyZenith = vm.Vector3(0.05, 0.20, 0.62);
  static final vm.Vector3 _skyHorizon = vm.Vector3(0.46, 0.66, 0.92);
  static final vm.Vector3 _skyGround = vm.Vector3(0.14, 0.15, 0.16);

  /// 阴雨天把三色拉向的灰调（浑浊度越高越灰）。
  static final vm.Vector3 _skyHaze = vm.Vector3(0.58, 0.62, 0.68);

  /// 当前帧的天空基准色（闪电在它之上做瞬间增亮，见 [_applySkyColors]）。
  vm.Vector3 _baseZenith = vm.Vector3(0.05, 0.20, 0.62);
  vm.Vector3 _baseHorizon = vm.Vector3(0.46, 0.66, 0.92);
  vm.Vector3 _baseGround = vm.Vector3(0.14, 0.15, 0.16);
  vm.Vector3 _baseSunDisk = vm.Vector3(3.0, 2.7, 2.2);

  // ---- 云（三层）----

  /// 各层云的漂移角速度（rad/s）：整层绕世界原点旋转，半径 ~100~300m 时
  /// 线速度约 0.2~0.6 m/s，是"云慢慢飘"的观感；三层速度各不相同
  /// → 明显视差（一层云怎么调都像贴纸）。
  ///
  /// 云环铺宽之后（见 [build] 的半径），同一个角速度对应的**线速度整体变大**
  /// —— 外圈云会呼啸而过。所以这里的值按新半径下调过一轮：
  /// 判据是"外圈（~300m）线速度 ≈ 0.4~0.6 m/s"。
  static const double _cloudDriftHigh = 0.0015;
  static const double _cloudDriftMid = 0.0026;
  static const double _cloudDriftLow = 0.0042;

  /// 三层云：高层卷云 / 中层积云 / 低层层积云。
  final List<_CloudBand> _cloudBands = [];

  /// 云实例色是否需要重算。天气过渡期间每帧置起，平时不置 ——
  /// 云的颜色/不透明度只跟天气和太阳方位有关，跟时间无关，
  /// 每帧重算 300 多个实例色纯属浪费。
  bool _cloudDirty = true;

  /// 当前云色 / 云量 / 太阳方位（由 [_commit] 写入，供 [_tickClouds] 染色）。
  vm.Vector3 _cloudTint = vm.Vector3(1, 1, 1);
  double _cloudCover = 0.5;
  vm.Vector3 _sunAzimuth = vm.Vector3(0.4, 0, 0.6);

  // ---- 河谷雾体积 ----
  EnvironmentVolume? _mistVolume;

  // ---- 夜空 ----

  /// 背景星数量。分布密度由噪声调制：有密集区也有稀疏区，
  /// 全均匀撒出来的星空一眼就是"程序生成的"。
  ///
  /// 500 + 银河带 400 = 900 颗。刻意留出大片黑底：
  /// 星星铺得越满越像"星空壁纸"，而稀疏的暗区才是夜空的呼吸感来源。
  static const int _starCount = 500;

  /// 银河带补充星数量。它们额外叠在银道面附近，密度远高于背景，
  /// 与那一层弥散光带（[_buildGalaxyBandGeometry]）一起读成"银河"。
  static const int _galaxyStarCount = 400;

  /// 银道面极轴。
  ///
  /// 星空不再各向同性：|dir · 极轴| 小的方向即银河所在的大圆。
  /// 极轴特意选得**倾斜且不过头顶**（y 分量 0.84），这样银河带会
  /// 斜跨天顶，而不是像一条人造的纬线横在正上方。
  static final vm.Vector3 _galacticPole =
      vm.Vector3(0.34, 0.84, -0.42).normalized();

  InstancedMesh? _starMesh;
  Node? _nightNode;
  UnlitMaterial? _moonMaterial;

  /// 月晕：一张朝向相机的渐变圆盘（billboard）。
  ///
  /// **不用更大的球体**：球面到月心等距，顶点色梯度做不出"中心亮、
  /// 边缘淡"的衰减，只会得到一个实心的半透明大球。必须用平面 + 朝向相机。
  UnlitMaterial? _moonGlowMaterial;
  Node? _moonGlowNode;

  final List<vm.Vector4> _starBaseColors = [];
  final List<double> _starTwinkleSpeed = [];
  final List<double> _starTwinklePhase = [];
  final List<double> _starTwinkleAmp = [];
  int _frameNonce = 0;

  /// 月亮的 HDR 基色：>1 的亮度会吃 bloom，形成柔光月晕。
  static final vm.Vector4 _moonBaseColor = vm.Vector4(1.45, 1.40, 1.26, 1.0);

  // ---- 流星 ----

  /// 流星：一根沿轨迹拉长的亮条（+ 头部亮球）。
  ///
  /// 只有一条实例（一个节点 + 一个子节点），开销可以忽略；
  /// 但它让静态的星空"活"了起来——夜晚与白天的区别不止是亮度，
  /// 还有"看点"（星星闪、流星划、月亮挂）。
  UnlitMaterial? _meteorMaterial;
  Node? _meteorNode;

  /// 距离下一颗流星的冷却（秒）。
  double _meteorCool = 6.0;
  double _meteorProgress = 1.0; // >=1 表示未激活
  double _meteorDuration = 1.0;
  vm.Vector3 _meteorStart = vm.Vector3.zero();
  vm.Vector3 _meteorEnd = vm.Vector3.zero();

  // ---- 雨幕 ----

  /// 雨丝数量：2200 根。密度是雨势观感的第一要素 —— 1500 根时
  /// 满雨量下画面仍然"看得出是雨、但不是大雨"（实测）。
  ///
  /// 成本可控：雨幕实例缓冲只有 2200×20 float ≈ 176KB，
  /// 相比草地的 8.8MB 微不足道，所以每帧全量更新是安全的。
  static const int _rainCount = 2200;

  InstancedMesh? _rainMesh;
  UnlitMaterial? _rainMaterial;
  bool _rainVisible = false;
  final List<vm.Vector3> _rainDrops = [];
  final List<double> _rainLengthJitter = [];
  final List<double> _rainSpeedJitter = [];
  final List<double> _rainFade = [];
  /// 每滴的横向漂移系数：让雨幕不是所有雨丝严格平行，
  /// 而是有细微的"毛边"（真实雨幕的湍流感就在这点抖动上）。
  final List<double> _rainDriftX = [];

  /// 阵风强度（0.72–1.28，由慢频噪声/正弦驱动）。
  /// 大雨不是恒速的：一阵一阵的斜落比匀速直落真实得多，
  /// 也让雨幕在时间上有"呼吸"，而不是一帧帧完全相同的纹理。
  double _gust = 1.0;

  // ---- 闪电 ----

  /// 当前闪光强度 0–1（0 = 无）。由 [_tickLightning] 驱动，
  /// 同时把亮度叠到平行光 / 天穹染色 / 雨丝材质上。
  double _flash = 0;
  double _lightningCool = 14.0;
  double _lightningTimer = 0;
  double _lightningDuration = 0;

  /// 天气档下发的基准光照强度与天穹染色。
  ///
  /// 闪电是**叠加**在基准之上的瞬间增亮，所以必须把 [_commit] 算出的
  /// 基准值存下来，每帧用 `基准 × (1 + flash·k)` 重算，
  /// 而不是直接改 `_sunLight.intensity`（那样基准就被吃掉了）。
  double _baseSunIntensity = 1.0;

  /// 把天空盒四色按 [k] 倍写入。平时 k = 1；闪电时 k > 1，
  /// 于是"整个天被照亮"而不是"平行光忽然变强"。
  void _applySkyColors(double k) {
    _skySource
      ..zenithColor = _baseZenith * k
      ..horizonColor = _baseHorizon * k
      ..groundColor = _baseGround * k
      ..sunColor = _baseSunDisk * k;
  }

  /// 雨丝基准长度（米）。0.28 在 8.5m 处约 40~45px，看着像雨。
  static const double _rainStreakBase = 0.28;

  /// 雨丝在屏幕上的目标宽度（像素，@1600px 宽）。
  static const double _rainScreenWidthPx = 1.6;
  static const double _rainRefViewportPx = 1600.0;
  static const double _rainRefFovRad = 1.0472; // 60°

  static double _widthForDistance(double camDist) {
    final worldW = 2.0 * camDist * math.tan(_rainRefFovRad * 0.5);
    return _rainScreenWidthPx / _rainRefViewportPx * worldW;
  }

  static const double _rainNearFadeStart = 3.0;
  static const double _rainNearFadeEnd = 0.8;
  static const double _rainColumnTop = 20.0;
  static const double _rainGroundSlack = 1.5;

  /// 隐藏实例用的变换：缩放到 0。
  ///
  /// **不能用 `Matrix4.zero()`**：退化矩阵会把几何塌缩到世界原点一个点
  /// （实测表现为画面正中一根贯穿天地的白柱）。
  static final vm.Matrix4 _hiddenTransform = vm.Matrix4.compose(
    vm.Vector3.zero(),
    vm.Quaternion.identity(),
    vm.Vector3.zero(),
  );

  static const double _rainFieldSize = 42.0;
  static const double _rainFallSpeed = 17.0;

  /// 风偏速度（m/s）。乘阵风后让斜落角度随时间变化。
  double get _rainWindSpeed => 4.6 * current.rainAmount * _gust;

  /// 雨丝颜色。偏冷（略蓝）、透明度低。
  static final vm.Vector4 _rainColor = vm.Vector4(0.78, 0.86, 0.97, 0.34);

  /// 雨丝在闪电瞬间被照亮的颜色（近似白）。
  static final vm.Vector4 _rainFlashColor = vm.Vector4(0.95, 0.97, 1.0, 0.5);

  // ---- 水花与积水 ----

  /// 水花池容量。150 个够铺满近场：水花寿命只有 0.4–0.7s，
  /// 池子太大也只是白占内存，关键是**生成速率**要与雨势匹配。
  static const int _splashPool = 150;
  InstancedMesh? _splashMesh;
  final List<vm.Vector3> _splashPos = [];
  final List<double> _splashAge = [];
  final List<double> _splashLife = [];
  final List<double> _splashScale = [];
  final List<bool> _splashActive = [];
  double _splashSpawnAccumulator = 0;
  int _splashCursor = 0;

  static const int _puddleCount = 72;
  InstancedMesh? _puddleMesh;
  Node? _puddleNode;
  bool _puddleVisible = false;

  /// 积水落点与尺度：涟漪必须长在水面上，所以积水盘的位置要存下来。
  final List<vm.Vector3> _puddleSpots = [];
  final List<double> _puddleScale = [];

  // ---- 积水涟漪 ----

  /// 涟漪池。与水花刻意区分开：
  ///   * 水花 = 雨点砸在土地上：小而亮、扩散快、寿命 0.4–0.7s；
  ///   * 涟漪 = 雨点打在水面上：大而淡、扩散慢、寿命 0.9–1.6s。
  /// 两者叠在一起才有"到处都在下雨"的错觉。
  static const int _ripplePool = 140;
  InstancedMesh? _rippleMesh;
  final List<vm.Vector3> _ripplePos = [];
  final List<double> _rippleAge = [];
  final List<double> _rippleLife = [];
  final List<double> _rippleScale = [];
  final List<bool> _rippleActive = [];
  double _rippleAccumulator = 0;
  int _rippleCursor = 0;

  WeatherKind _kind = WeatherKind.clear;
  WeatherKind get kind => _kind;

  double _blend = 1.0;
  WeatherProfile _from = WeatherProfile.presets[WeatherKind.clear]!;
  WeatherProfile _to = WeatherProfile.presets[WeatherKind.clear]!;

  WeatherProfile get current => _interpolate(_from, _to, _blend);

  double get windStrength => current.grassWind;

  /// 雾色里取自天空的比例（空气透视强度）。
  ///
  /// 白天要它偏高：远山褪进天光、和头顶的天色对上，"远处是空气而不是墙"。
  /// 夜里必须收小 —— 夜空本身是暗的，雾采样到暗色会把远处地形整片吃掉，
  /// 山谷会变成一个黑洞（而不是"远处的山没入夜色"）。
  double get fogSkyColorInfluence => 0.55 * (1.0 - 0.78 * current.nightAmount);

  /// 雾色（线性），全局雾与河谷雾体积**共用同一个来源**。
  ///
  /// **夜景必须额外压暗**：`skyTint` 是"白昼天光的染色乘子"，它的量级是按
  /// 白天调的；直接拿去当雾色（引擎把雾色当线性色、后面还有 tone mapping），
  /// 夜里会渲染成一片**中亮蓝**。
  /// 实测后果：河谷雾体积把夜景画面均值从 29.8 抬到 **50.2**、
  /// `暗(<32)` 占比从 61.2% 掉到 **0.3%** —— 河谷比周围地形亮 68%，
  /// 看上去像地上放了一个发光的蓝盒子，而雾本该只是"月光里的水汽"。
  /// 压到 0.12 后谷雾只比周围亮一点点。
  vm.Vector3 get fogColor => _fogColorFor(current);

  static vm.Vector3 _fogColorFor(WeatherProfile p) {
    final k = 1.0 - 0.88 * p.nightAmount;
    return vm.Vector3(
      p.skyTint.r * 0.78 * k,
      p.skyTint.g * 0.84 * k,
      p.skyTint.b * 0.90 * k,
    );
  }

  /// 河谷雾体积的 settings。
  ///
  /// **必须用同一个 [buildKirbyLook] 造、只覆写雾相关字段**，不能只写几项就完事：
  /// 引擎混合 base 与体积走的是 `EnvironmentSettings.lerp(base, volume.settings, w)`
  /// —— **逐字段**插值。体积里没写的字段会被拉向 `EnvironmentSettings` 的
  /// **构造默认值**，而不是"保持 base 不动"。
  ///
  /// 早先这里只写了 `skybox` + 雾那几项，于是相机一进河谷：泛光、色彩分级、
  /// 环境光遮蔽、暗角、雾的 cutoff / 高度衰减 / 天光占比**全部**被拉回默认，
  /// 整屏洗成一片均质的亮蓝（实测夜景谷内均值 46.5、`暗(<32)` 只剩 2.6%，
  /// ASCII 里连一座山脊都读不出来；谷外是 28.7）。
  EnvironmentSettings _buildMistSettings(WeatherProfile p) {
    final s = buildKirbyLook(
      fogDensity: p.fogDensity,
      exposure: p.exposure,
      environmentIntensity: p.environmentIntensity,
      fogColor: _fogColorFor(p),
      fogSkyColorInfluence: 0.55 * (1.0 - 0.78 * p.nightAmount),
      skybox: _skybox,
    );
    _applyMistFog(s, p);
    return s;
  }

  /// 把"谷雾与全局雾的差异"写进体积 settings。
  /// 除雾以外的字段与 base **逐字相同**（见 [_buildMistSettings]）。
  void _applyMistFog(EnvironmentSettings s, WeatherProfile p) {
    s
      ..exposure = p.exposure
      ..environmentIntensity = p.environmentIntensity
      ..fogColor = _fogColorFor(p)
      ..fogSkyColorInfluence = 0.55 * (1.0 - 0.78 * p.nightAmount);
    // **夜里谷雾要更薄**。白天雾浓度是"景深"（远景逐层褪掉）；
    // 夜里地面本身几乎不反光（实测夜景谷外均值 28.7），雾还是那个浓度，
    // 河谷就会变成一墟比周围亮 62% 的蓝墙。
    final mistThin = 1.0 - 0.65 * p.nightAmount;
    s.fogDensity =
        (0.0040 + p.fogDensity * 2.2 + p.valleyMist * 0.010) * mistThin;
  }

  bool get isTransitioning => _blend < 1.0;

  /// 引擎天空盒。世界侧下发外观时要带上它，否则 `scene.skybox` 会被清成 null。
  Skybox get skybox => _skybox;

  /// 组装进场景。返回值仅为兼容旧签名（世界侧不使用）。
  Node build(Scene scene) {
    // ---- 天空盒：引擎的 `GradientSkySource` ----
    // 挂在 `Scene.skybox` 上，整屏绘制在一切几何之后，天然不受距离雾影响。
    _skySource = GradientSkySource(
      sunDirection: WeatherProfile.presets[WeatherKind.clear]!.sunToward,
      sunSharpness: 1400.0, // 太阳盘收得紧一点，才像"太阳"而不是一片白光
    );
    _skybox = Skybox(_skySource);
    scene.skybox = _skybox;

    // ---- 云（三层）----
    // 高度与半径按"相机能拍到"反推：云的仰角 = atan(高度 / 水平距) 必须落进
    // **画面实际覆盖的仰角带**——太低会整层出画，太高会挤在画面上缘一条。
    //
    // 这条带是算出来的，不是拍的：相机 `fovRadiansY` 60°、默认俯角 5.7°，
    // 画面纵向覆盖地平线上方 **0°~24.3°**。所以每种云的仰角下限
    // `atan(yMax / rMax)` 要压到 10° 以下，才能真正铺满天空。
    // 早先的 rSpread 只到 105/86/62（仰角下限 15.4°/17.4°/20.6°），
    // 结果是**全部云团挤在画面上缘 5% 里**、下面 20° 一片空渐变
    // （默认视角实测：9~21° 仰角完全无云）。所以这里把环铺宽到 rMax≈320/253/190。
    // 三层刻意拉开高度与速度：只在同一个高度堆两三层，读起来还是一片。
    final puff = _buildCloudPuffGeometry();
    _cloudBands
      ..add(_buildCloudBand(
        puff: puff,
        name: 'clouds_high',
        // 数量随云环面积一起上调：铺宽之后同样多的云摊在 4 倍大的环带上，
        // 天空会被“稀释”成稀稀几团（实测过）。
        count: 46,
        yBase: 62.0,
        ySpread: 22.0,
        rBase: 60.0,
        rSpread: 260.0,
        blobsMin: 3,
        blobsMax: 5,
        stretch: 2.2, // 高层卷云：拉得很扁、很宽
        puffScale: 5.5,
        baseAlpha: 0.55,
        drift: _cloudDriftHigh,
      ))
      ..add(_buildCloudBand(
        puff: puff,
        name: 'clouds_mid',
        count: 32,
        yBase: 42.0,
        ySpread: 16.0,
        rBase: 48.0,
        rSpread: 205.0,
        blobsMin: 4,
        blobsMax: 6,
        stretch: 1.25,
        puffScale: 6.5,
        baseAlpha: 0.82,
        drift: _cloudDriftMid,
      ))
      ..add(_buildCloudBand(
        puff: puff,
        name: 'clouds_low',
        count: 22,
        yBase: 28.0,
        ySpread: 12.0,
        rBase: 40.0,
        rSpread: 150.0,
        blobsMin: 5,
        blobsMax: 8,
        stretch: 0.95, // 低层积云圆润成团
        puffScale: 7.5,
        baseAlpha: 1.0,
        drift: _cloudDriftLow,
      ));
    for (final b in _cloudBands) {
      scene.add(b.node);
    }

    // ---- 河谷雾体积 ----
    // 相机下到河谷时雾变浓（大气体积效果）；覆盖整条河谷走廊，
    // blendDistance 让进出河谷是平滑过渡而不是硬切。
    // 初值用晴朗档算一遍，真实的逐天气值由 `_commit` 里的 [_applyMistFog] 写入。
    final mist = _buildMistSettings(WeatherProfile.presets[WeatherKind.clear]!);
    _mistVolume = EnvironmentVolume(
      settings: mist,
      bounds: BoxVolumeBounds(
        center: vm.Vector3(32.0, 2.0, 0.0), // 河道中心线 x 的均值
        halfExtents: vm.Vector3(15.0, 8.0, 75.0),
      ),
      // blendDistance 是"体积外溢"的距离：20m 时玩法区（离河谷边缘 ~11m）
      // 也会被混进 65% 的浓雾 —— 整个天空被洗成灰白（实测）。
      // 收到 10m 后玩法区在影响范围之外，进谷才会起雾。
      blendDistance: 10.0,
      weight: 0.45,
    );
    // 谷雾体积。**必须在 `Scene.baseEnvironment` 被设置之后才有意义**：
    // 引擎在 base 为 null 时直接跳过整段体积混合（见 sky.dart 文件头）。
    // 世界侧在 `_applyLook` 里设 baseEnvironment，这里只登记体积。
    scene.environmentVolumes.add(_mistVolume!);

    // ---- 平行光（太阳/月亮）----
    // 用**场景级** `directionalLight` 便利入口，而不是给节点挂
    // DirectionalLightComponent：后者 debug 构建会断言失败，且
    // `light.direction` 的写入会被静默忽略（组件只在创建时读一次）。
    scene.directionalLight = _sunLight;

    // ---- 雨幕 ----
    _rainMesh = _buildRain();
    scene.add(Node(name: 'rain')..addComponent(InstancedMeshComponent(_rainMesh!)));

    // ---- 夜空（星星 + 月亮）----
    _buildNight(scene);

    // ---- 水花与积水 ----
    _splashMesh = _buildSplashPool();
    scene.add(Node(name: 'rain_splash')
      ..addComponent(InstancedMeshComponent(_splashMesh!)));
    // 积水必须在涟漪之前构建：涟漪的出生点来自 _puddleSpots。
    _puddleMesh = _buildPuddles();
    _puddleNode = Node(name: 'puddles')
      ..addComponent(InstancedMeshComponent(_puddleMesh!));
    scene.add(_puddleNode!);
    _rippleMesh = _buildRipplePool();
    scene.add(Node(name: 'rain_ripple')
      ..addComponent(InstancedMeshComponent(_rippleMesh!)));

    applyWeather(_kind, instant: true);
    // 返回值仅为兼容旧签名；用引擎天空盒时没有天穹节点，给个占位。
    return Node(name: 'sky_root');
  }

  /// 切换天气；[instant] 为 true 时跳过过渡并立即下发参数。
  void applyWeather(WeatherKind kind, {bool instant = false}) {
    final alreadyThere = kind == _kind && _blend >= 1.0;
    if (alreadyThere && !instant) return;

    _from = current;
    _to = WeatherProfile.presets[kind]!;
    _kind = kind;
    _blend = instant ? 1.0 : 0.0;
    if (instant) _commit(_to);
  }

  /// 在四种天气之间循环（UI/键盘快捷键用）。
  WeatherKind cycle() {
    final next = WeatherKind.values[(_kind.index + 1) % WeatherKind.values.length];
    applyWeather(next);
    return next;
  }

  void tick(double dt, double time, {vm.Vector3? focus, vm.Vector3? cameraPos}) {
    if (_blend < 1.0) {
      _blend = (_blend + dt * 0.6).clamp(0.0, 1.0); // 约 1.7 秒过渡完
      _commit(current);
    }

    final origin = focus ?? vm.Vector3.zero();
    final amount = current.rainAmount;
    final night = current.nightAmount;

    // 阵风：两个不同频率的正弦相加，避免读成"周期性呼吸"。
    // 相位由累计时间驱动，与帧率无关。
    _gust = 1.0 +
        0.18 * math.sin(time * 0.9 + 0.7) +
        0.10 * math.sin(time * 2.3 + 2.1);

    _tickClouds(dt);
    // 夜空的更新量很小（只有闪烁与月亮朝向），但需要相机位置：
    // 月晕是一张朝向相机的 billboard。
    _tickNight(dt, time, night, cameraPos);
    _tickRain(dt, origin, cameraPos, amount);
    _tickSplashes(dt, origin, amount);
    _tickRipples(dt, origin, amount);
    _tickPuddles(amount, time);
    // 闪电放在最后：它叠加到平行光/天穹/雨丝上，
    // 必须晚于 _commit 与 _tickRain 的写入。
    _tickLightning(dt, amount);
  }

  // ------------------------------------------------------------------
  // 云
  // ------------------------------------------------------------------

  /// 云的漂移：整层绕世界原点缓慢旋转。三层速度不同 → 视差。
  /// 每帧只写三个四元数，实例矩阵完全不动（零重打包开销）；
  /// 实例色只在天气变化时重算（[_cloudDirty]）。
  void _tickClouds(double dt) {
    // `vm.Vector3` 不是 const 构造（它内部是可变字段），只能 final。
    final up = vm.Vector3(0, 1, 0);
    for (final b in _cloudBands) {
      b.yaw += dt * b.drift;
      b.node.rotation = vm.Quaternion.axisAngle(up, b.yaw);
    }
    if (!_cloudDirty) return;
    _cloudDirty = false;
    for (final b in _cloudBands) {
      for (var i = 0; i < b.spots.length; i++) {
        b.mesh.setInstanceColor(i, _cloudInstanceColor(b, i));
      }
    }
  }

  /// 单团云的实例色（RGB 色调 + A 不透明度）。
  ///
  /// 两件事在这里发生：
  ///
  ///  1. **云量用"逐团阈值"而不是整层淡出**。整层 alpha 缩小只是
  ///     "整体变淡"，看着像一层半透明塑料膜；而给每团云一个固定的
  ///     随机阈值、用云量去越过它，效果是**云团的数量随天气增减**：
  ///     晴 → 阴是云一团团长出来，阴 → 晴是一团团散掉 —— 这才是云。
  ///     （阈值把云量映射成 0..1 再平方，淡入淡出也不会硬切。）
  ///  2. **日照侧泛暖、背光侧沉灰**。云团水平方位与太阳方位的点积
  ///     给出"迎光/背光"，迎光面提亮并偏暖、背光面压暗偏冷。
  ///     代价只是构建时存下每团的位置（见 [_buildCloudBand]）。
  vm.Vector4 _cloudInstanceColor(_CloudBand band, int i) {
    final thr = band.thresholds[i];
    final appear = ((_cloudCover - thr) / math.max(0.10, 1.0 - thr))
        .clamp(0.0, 1.0);
    final a = band.baseAlpha * appear * appear;
    if (a <= 0.004) return vm.Vector4(0, 0, 0, 0);

    final s = band.spots[i];
    final hl = math.sqrt(s.x * s.x + s.z * s.z);
    var warm = 0.5;
    if (hl > 1e-4) {
      warm = 0.5 +
          0.5 * ((s.x / hl) * _sunAzimuth.x + (s.z / hl) * _sunAzimuth.z);
    }
    // 迎光面多亮 28%，蓝通道略收（暖），背光面沉下去（冷）。
    final lit = 0.70 + 0.30 * warm;
    return vm.Vector4(
      _cloudTint.x * lit * (1.0 + 0.10 * warm),
      _cloudTint.y * lit * (1.0 + 0.03 * warm),
      _cloudTint.z * lit * (1.0 - 0.07 * warm),
      a,
    );
  }

  /// 云的"云泡"几何：一个球面，顶点色按高度从下到上渐亮。
  ///
  /// **为什么不用 `IcosphereGeometry`**：它没有顶点色，整团云一个颜色，
  /// 看上去就是一团白塑料。而真实云团的第一眼特征就是"顶亮底暗"——
  /// 把明暗烘进顶点色后，一个球就有一颗蓬松球体的体积感，
  /// 而且比再加一层几何便宜（这张几何被三层云共用）。
  MeshGeometry _buildCloudPuffGeometry() {
    const rings = 8;
    const segments = 14;
    final b = GeometryBuilder(deduplicate: false);
    for (var r = 0; r <= rings; r++) {
      final phi = math.pi * r / rings;
      final ny = math.cos(phi);
      final sinPhi = math.sin(phi);
      // 顶亮底暗；指数 <1 让亮部铺得宽（云顶是一片平亮，不是一个小点）。
      final t = (0.5 + 0.5 * ny).clamp(0.0, 1.0);
      final v = 0.56 + 0.44 * math.pow(t, 0.75).toDouble();
      for (var s = 0; s <= segments; s++) {
        final theta = math.pi * 2 * s / segments;
        b
          ..color(vm.Vector4(v, v, v * 1.03, 1.0))
          ..addVertex(vm.Vector3(
            sinPhi * math.cos(theta),
            ny,
            sinPhi * math.sin(theta),
          ));
      }
    }
    for (var r = 0; r < rings; r++) {
      for (var s = 0; s < segments; s++) {
        final a = r * (segments + 1) + s;
        final c = a + segments + 1;
        b
          ..addTriangle(a, a + 1, c)
          ..addTriangle(a + 1, c + 1, c);
      }
    }
    return b.build();
  }

  /// 生成一层云：若干"云团"，每个云团由数个压扁的云泡组成。
  /// 分布用域扭曲打散（与植被同一招），避免云团排成规则环带。
  _CloudBand _buildCloudBand({
    required MeshGeometry puff,
    required String name,
    required int count,
    required double yBase,
    required double ySpread,
    required double rBase,
    required double rSpread,
    required int blobsMin,
    required int blobsMax,
    required double stretch,
    required double puffScale,
    required double baseAlpha,
    required double drift,
  }) {
    final material = UnlitMaterial()
      // 中性白：颜色与不透明度全部由实例色给（顶点色 × 实例色）。
      ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
      ..vertexColorWeight = 1.0
      ..alphaMode = AlphaMode.blend
      ..doubleSided = true;
    final mesh = InstancedMesh(geometry: puff, material: material);
    final band = _CloudBand(
      mesh: mesh,
      node: Node(name: name),
      drift: drift,
      baseAlpha: baseAlpha,
    );

    for (var i = 0; i < count; i++) {
      final a = _rng.nextDouble() * math.pi * 2;
      final r = rBase + _rng.nextDouble() * rSpread;
      final cx = math.cos(a) * r;
      final cz = math.sin(a) * r;
      final cy = yBase + _rng.nextDouble() * ySpread;

      // 域扭曲：让云团在环带上错落，不排成同心圆。
      final wx =
          _noise.fbm2(cx * 0.02 + 5.0, cz * 0.02 - 3.0, octaves: 2) * 22.0;
      final wz =
          _noise.fbm2(cx * 0.02 - 11.0, cz * 0.02 + 7.0, octaves: 2) * 22.0;
      final ccx = cx + wx;
      final ccz = cz + wz;

      final blobs = blobsMin + _rng.nextInt(blobsMax - blobsMin + 1);
      // **云泡尺寸随水平距离等比放大 → 角尺寸不随半径缩小**。
      //
      // 为什么必须有这一条：云的"能看到多少"由它的**仰角** `atan(y / r)` 决定。
      // 相机 fov 60°、默认俯角 5.7° → 画面里的天空是地平线上方 0~24°；
      // 原来云环只铺到 r≈165，仰角下限 15°（中低层 15.4°/17.4°）——
      // 结果**整片云都挤在画面上缘 5% 里**，下面 20° 的天空是一片空渐变
      // （实测：默认视角下 9~21° 仰角完全无云）。把环铺宽（见 [build]）才进得了画面，
      // 但半径一拉大，同样大的云泡角尺寸就变小 "云越远越小"。
      // 按 `r / rBase` 等比放大后角尺寸恒定，铺多宽都是一样的云。
      final dist = math.min(6.0, math.max(1.0, r / rBase));
      final cloudScale = puffScale * dist * (0.8 + _rng.nextDouble() * 0.5);
      for (var k = 0; k < blobs; k++) {
        final bx = ccx + (_rng.nextDouble() - 0.5) * cloudScale * 1.7;
        final bz = ccz + (_rng.nextDouble() - 0.5) * cloudScale * 1.3;
        final by = cy + (_rng.nextDouble() - 0.5) * cloudScale * 0.26;
        final sx = cloudScale * (0.75 + _rng.nextDouble() * 0.6) * stretch;
        final sy = cloudScale * (0.34 + _rng.nextDouble() * 0.18);
        final sz = cloudScale * (0.75 + _rng.nextDouble() * 0.6) / stretch;
        mesh.addInstance(
          vm.Matrix4.compose(
            vm.Vector3(bx, by, bz),
            vm.Quaternion.axisAngle(
                vm.Vector3(0, 1, 0), _rng.nextDouble() * math.pi * 2),
            vm.Vector3(sx, sy, sz),
          ),
          color: vm.Vector4(0, 0, 0, 0), // 首帧即由 _cloudDirty 重算
        );
        // 同一云团的每个云泡共享位置与阈值，所以"团"是同时出现/消失的
        // （逐泡各自随机会让云团一边长一边散，显得很碎）。
        band.spots.add(vm.Vector3(bx, by, bz));
        band.thresholds.add(_cloudThresholdFor(i));
      }
    }
    band.node.addComponent(InstancedMeshComponent(mesh));
    return band;
  }

  /// 云团的"出现阈值" 0–1：越小越早出现。
  ///
  /// 用**层内排序**而不是纯随机：纯随机会让稀疏的天气下出现"东边一团、
  /// 西边三团"的斑贴感；按阈值大小铺开、云量变高时从低到高逐个越线，
  /// 云量的变化才是一条"云慢慢长满天空"的连续过程。
  double _cloudThresholdFor(int index) =>
      (index * 0.147) % 1.0 * 0.72 + _rng.nextDouble() * 0.28;

  // ------------------------------------------------------------------
  // 夜空
  // ------------------------------------------------------------------

  void _tickNight(
    double dt,
    double time,
    double night,
    vm.Vector3? cameraPos,
  ) {
    final node = _nightNode;
    if (node == null) return;

    // 夜元素整体显隐：夜量低于阈值时整棵子树缩放为 0（零成本跳过绘制），
    // 过渡期间靠实例色渐显，不会突然弹出。
    final visible = night > 0.015;
    final scale = node.scale;
    if (visible && scale.x == 0) {
      node.scale = vm.Vector3(1, 1, 1);
    } else if (!visible && scale.x != 0) {
      node.scale = vm.Vector3.zero();
      return;
    }
    if (!visible) return;

    // 月亮：亮度随夜量走，>1 的 HDR 亮度交给 bloom 做月晕。
    _moonMaterial?.baseColorFactor = vm.Vector4(_moonBaseColor.r * night,
        _moonBaseColor.g * night, _moonBaseColor.b * night, 1.0);

    // 月晕：一张朝向相机的渐变圆盘，亮度/透明度随夜量。
    // 远看月亮不是一个硬边白点，而是中心极亮、向外层层变淡的光斑。
    final glow = _moonGlowNode;
    if (glow != null) {
      _moonGlowMaterial?.baseColorFactor = vm.Vector4(
          _moonBaseColor.r,
          _moonBaseColor.g * 0.98,
          _moonBaseColor.b * 0.92,
          0.55 * night);
      final eye = cameraPos ?? vm.Vector3.zero();
      final towardCamera = eye - glow.position;
      if (towardCamera.length2 > 1e-6) {
        glow.rotation = _facingQuaternion(towardCamera);
      }
    }

    _tickMeteor(dt, night);

    // 星星闪烁：每 3 帧更新一次实例色（约 20Hz，肉眼足够顺滑）。
    // 只在夜间更新 —— 白天这一整个循环都是零开销。
    if (_frameNonce++ % 3 != 0) return;
    final mesh = _starMesh;
    if (mesh == null) return;
    // 分布噪声可能拒绝过多候选，实际数量以列表长度为准。
    final count = _starBaseColors.length;
    for (var i = 0; i < count; i++) {
      final base = _starBaseColors[i];
      final phase = time * _starTwinkleSpeed[i] + _starTwinklePhase[i];
      // 双频闪烁：主频像"眨眼"，慢频调制它的幅度。
      // 单频正弦会让整片星空像同一盏灯在闪（实测一股塑料感）；
      // 两个不互成整倍数的频率叠起来，每颗星的节奏才互不相同。
      final amp = _starTwinkleAmp[i];
      final tw = 1.0 -
          amp *
              (0.5 + 0.5 * math.sin(phase)) *
              (0.6 + 0.4 * math.sin(phase * 0.41 + _starTwinklePhase[i]));
      mesh.setInstanceColor(
        i,
        vm.Vector4(base.r * tw * night, base.g * tw * night,
            base.b * tw * night, 1.0),
      );
    }
  }

  /// 流星：隔一段时间出现一颗，划过天空后淡出。
  ///
  /// 只在天色够黑时才出现（夜量 > 0.6），否则白天会看到"天上有条白线"。
  /// 整个流星子树挂在 _nightNode 下，白天随整棵子树零缩放隐藏。
  void _tickMeteor(double dt, double night) {
    final node = _meteorNode;
    if (node == null) return;

    if (_meteorProgress >= 1.0) {
      // 待机：只有夜足够深才开始计时，避免白天一直在攒冷却。
      if (night < 0.6) return;
      _meteorCool -= dt;
      if (_meteorCool > 0) return;
      _spawnMeteor();
    }

    _meteorProgress += dt / _meteorDuration;
    if (_meteorProgress >= 1.0) {
      _meteorProgress = 1.0;
      node.scale = vm.Vector3.zero();
      node.position = vm.Vector3.zero();
      return;
    }

    // 位置：匀加速一点（用 t² 的轻微缓入），像被引力拽下来的流星。
    final t = _meteorProgress;
    final eased = t * t * (3 - 2 * t) * 0.35 + t * 0.65;
    node.position = _meteorStart + (_meteorEnd - _meteorStart) * eased;

    // 亮度/长度包络：两端淡，中段最亮最长，看上去像"拖着尾巴划过"。
    final env = math.sin(math.pi * t);
    _meteorMaterial?.baseColorFactor = vm.Vector4(
        0.95,
        0.97,
        1.0,
        (0.55 * env * night).clamp(0.0, 1.0),
    );
    final length = 16.0 + 26.0 * env;
    node.scale = vm.Vector3(1.0, 1.0, length);
    // 亮丝朝向由自己的飞行方向决定（几何沿 +Z 拉长）。
    node.rotation = _facingQuaternion(_meteorEnd - _meteorStart);
  }

  void _spawnMeteor() {
    // 起点：天顶附近的随机方向（流星多数从高处斜掠而下）。
    final theta = _rng.nextDouble() * math.pi * 2;
    final y = 0.45 + _rng.nextDouble() * 0.45;
    final rxz = math.sqrt(math.max(0.0, 1.0 - y * y));
    final startDir =
        vm.Vector3(rxz * math.cos(theta), y, rxz * math.sin(theta));
    _meteorStart = startDir * (domeRadius * 0.92);

    // 飞行方向：在起点切平面上随机取一个朝下的方向，
    // 长度取 90–150m → 约 0.7–1.2 秒划完，是肉眼能跟上的速度。
    final jitter = vm.Vector3(
      _rng.nextDouble() * 2 - 1,
      _rng.nextDouble() * 2 - 1,
      _rng.nextDouble() * 2 - 1,
    );
    var tangent = jitter.cross(startDir);
    if (tangent.length2 < 1e-6) tangent = vm.Vector3(1, 0, 0).cross(startDir);
    tangent.normalize();
    if (tangent.y > 0) tangent = -tangent;
    final travel = (tangent + startDir * -0.35).normalized();
    _meteorEnd = _meteorStart + travel * (90.0 + _rng.nextDouble() * 60.0);

    _meteorDuration = 0.7 + _rng.nextDouble() * 0.5;
    _meteorProgress = 0.0;
    // 下一次冷却：8–26 秒，偶发才像流星（频繁就成流星雨了）。
    _meteorCool = 8.0 + _rng.nextDouble() * 18.0;
  }

  /// 构造一个把物体的 +Z 轴对齐到 [forward] 的旋转。
  ///
  /// 用于两张朝向相机的平面（月晕）与沿飞行方向拉长的流星。
  /// 直接用 `axisAngle` 只能绕单一固定轴，无法任意朝向。
  static vm.Quaternion _facingQuaternion(vm.Vector3 forward) {
    final f = forward.normalized();
    // 前向接近天顶时，默认的 up 与它几乎共线，叉积会退化 → 换一个参照。
    final ref = f.y.abs() > 0.94 ? vm.Vector3(0, 0, 1) : vm.Vector3(0, 1, 0);
    final right = ref.cross(f).normalized();
    final up = f.cross(right).normalized();
    final m = vm.Matrix3.zero()..setColumns(right, up, f);
    return vm.Quaternion.fromRotation(m);
  }

  /// 星空 + 银河 + 月亮 + 月晕 + 流星。
  /// 全部挂在同一棵 `_nightNode` 子树下，白天整棵子树零缩放隐藏。
  void _buildNight(Scene scene) {
    _nightNode = Node(name: 'night');
    scene.add(_nightNode!);
    _nightNode!.scale = vm.Vector3.zero(); // 初始（白天）隐藏

    // ---- 星星 ----
    // 材质必须 blend + 顶点色：星星是"径向渐变的光点"，
    // 靠几何顶点色的 alpha 从中心淡到边缘。opaque 会直接忽略 alpha，
    // 而球体（无论多少细分）在屏幕上永远带硬边轮廓。
    _starMesh = InstancedMesh(
      geometry: _buildStarGeometry(),
      material: UnlitMaterial()
        ..vertexColorWeight = 1.0
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..alphaMode = AlphaMode.blend
        ..doubleSided = true,
    );

    // 背景星：整片天空都有，密度用噪声调制出疏密斑块。
    _scatterStars(
      count: _starCount,
      sizeScale: 1.0,
      brightnessScale: 1.0,
      accept: (dir, rng) =>
          _noise.fbm2(dir.x * 2.6 + 9.0, dir.z * 2.6 - 4.0, octaves: 2) >=
              -0.35,
    );

    // 银河带：|dir · 极轴| 小 = 靠近银道面。
    // 带内星更小、更暗、更密 —— 单看是"一片暗星"，
    // 叠上下面那层弥散光带才读成"银河"。
    _scatterStars(
      count: _galaxyStarCount,
      sizeScale: 0.70,
      // 密度降下来之后，把银河带里每颗星的亮度略提（0.66 → 0.72），
      // 否则银河会从"一条暗星带"变成"一片空白"。
      brightnessScale: 0.72,
      accept: (dir, rng) =>
          dir.dot(_galacticPole).abs() < 0.22 && rng.nextDouble() < 0.9,
    );

    _nightNode!.add(Node(name: 'stars')
      ..addComponent(InstancedMeshComponent(_starMesh!)));

    // ---- 银河弥散光带 ----
    // 一条环形的半透明带子（顶点色向两侧渐淡），而不是一堆光球 ——
    // 叠加的球会露出一个个圆盘边界，读成"悬在天上的肥皂泡"。
    final galaxyMaterial = UnlitMaterial()
      ..vertexColorWeight = 1.0
      ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
      ..alphaMode = AlphaMode.blend
      ..doubleSided = true;
    _nightNode!.add(Node(
      name: 'galaxy_band',
      mesh: Mesh(_buildGalaxyBandGeometry(), galaxyMaterial),
    ));

    // ---- 月亮 ----
    // **关键**：月亮的可视位置在光照行进方向的**反方向**上 ——
    // 直接拿光照方向当位置，月亮会被埋进地底（实测踩过）。
    final moonSkyDir = -WeatherProfile.moonDirection;
    // 半径与"看上去多大"的关系：视角 = 2·atan(r / (domeRadius×0.90))，
    // 14.2m 在 216m 处 ≈ 7.5°。月晕尺寸按 moonRadius 比例推导。
    const moonRadius = 14.2;
    final moonCenter = moonSkyDir * (domeRadius * 0.90);
    // 月光来向（从月亮指向光源）：给月面一点"受光倾向"。
    // 取 night 档 lightTravel 的反向 —— 这样月亮亮的那一侧与场景里月光
    // 照亮的方向是一致的，不会各说各话。
    final moonlightFrom =
        -WeatherProfile.presets[WeatherKind.night]!.lightTravel;
    _moonMaterial = UnlitMaterial()
      ..vertexColorWeight = 1.0
      ..baseColorFactor = vm.Vector4(0, 0, 0, 1);
    final moonNode = Node(
      name: 'moon',
      // 月面几何自带顶点色（边缘变暗 + 月海 + 受光倾向），
      // 不再是"一圏纯色球 + 十几个贴上去的暗圆片"。
      mesh: Mesh(
        _buildMoonGeometry(moonRadius, moonSkyDir, moonlightFrom),
        _moonMaterial!,
      ),
    )..position = moonCenter;
    _nightNode!.add(moonNode);

    // ---- 月晕 ----
    // 一张朝向相机的渐变圆盘（尺寸约 4.3 倍月半径）。
    // 它把月亮的"硬边亮球"变成"中心极亮、向外层层化开的光斑"；
    // bloom 负责更外圈的柔光，两者叠加才有夜晚的"空气感"。
    _moonGlowMaterial = UnlitMaterial()
      ..vertexColorWeight = 1.0
      ..baseColorFactor = vm.Vector4(0, 0, 0, 0)
      ..alphaMode = AlphaMode.blend
      ..doubleSided = true;
    _moonGlowNode = Node(
      name: 'moon_glow',
      mesh: Mesh(_buildGlowDiscGeometry(), _moonGlowMaterial!),
    )
      ..position = moonCenter
      ..scale = vm.Vector3(moonRadius * 4.3, moonRadius * 4.3, 1.0);
    _nightNode!.add(_moonGlowNode!);

    // ---- 流星 ----
    _meteorMaterial = UnlitMaterial()
      ..baseColorFactor = vm.Vector4(0.95, 0.97, 1.0, 0.0)
      ..alphaMode = AlphaMode.blend
      ..doubleSided = true;
    _meteorNode = Node(
      name: 'meteor',
      mesh: Mesh(CuboidGeometry(vm.Vector3(1, 1, 1)), _meteorMaterial!),
    )..scale = vm.Vector3.zero();
    _nightNode!.add(_meteorNode!);
  }

  /// 星星几何：朝向天空的**柔和圆盘**，顶点色 alpha 从中心淡到边缘。
  ///
  /// **为什么不用球体**：`IcosphereGeometry(subdivisions: 0)` 是 20 面体，
  /// 一个直径 8.8m 的亮星在 fov 60° / 1200px 下约 41px —— 轮廓直接读成
  /// "巨大的六边菱形方块"（实拍反馈）。就算加细分也治不了根：球体在屏幕上
  /// 永远有硬边。星点真正该有的样子是"中心亮、边缘化开"，
  /// 而带径向 alpha 渐变的圆盘能做到，且三角形数固定（不随细分膨胀）。
  MeshGeometry _buildStarGeometry() {
    const segments = 16;
    const midRadius = 0.42;
    const midAlpha = 0.52;

    final b = GeometryBuilder(deduplicate: false);
    // 中心亮核。
    b
      ..color(vm.Vector4(1, 1, 1, 1.0))
      ..addVertex(vm.Vector3.zero());
    // 中间过度环。
    for (var s = 0; s <= segments; s++) {
      final a = math.pi * 2 * s / segments;
      b
        ..color(vm.Vector4(1, 1, 1, midAlpha))
        ..addVertex(
            vm.Vector3(math.cos(a) * midRadius, math.sin(a) * midRadius, 0));
    }
    // 边缘环（alpha = 0）。
    for (var s = 0; s <= segments; s++) {
      final a = math.pi * 2 * s / segments;
      b
        ..color(vm.Vector4(1, 1, 1, 0.0))
        ..addVertex(vm.Vector3(math.cos(a), math.sin(a), 0));
    }

    const midStart = 1;
    const edgeStart = midStart + segments + 1;
    for (var s = 0; s < segments; s++) {
      // 中心扇形。
      b.addTriangle(0, midStart + s, midStart + s + 1);
      // 中间环 → 边缘环。
      b
        ..addTriangle(midStart + s, edgeStart + s, midStart + s + 1)
        ..addTriangle(midStart + s + 1, edgeStart + s, edgeStart + s + 1);
    }
    return b.build();
  }

  /// 往 [_starMesh] 撒一层星。
  ///
  /// 尺寸与亮度都走**幂律分布**（`pow(rng, k)`）：绝大多数星又小又暗，
  /// 少数又大又亮。均匀分布会让满天星星一样大、一样亮 —— 那是一张
  /// "星空壁纸"，不是夜空。真实星空的第一眼特征就是亮度的巨大跨度。
  void _scatterStars({
    required int count,
    required double sizeScale,
    required double brightnessScale,
    required bool Function(vm.Vector3 dir, math.Random rng) accept,
  }) {
    var placed = 0;
    var attempts = 0;
    final guard = count * 16;
    while (placed < count && attempts < guard) {
      attempts++;
      // 球面均匀采样（y 均匀即面积均匀），y 下限 0.05（贴地平线少放）。
      final theta = _rng.nextDouble() * math.pi * 2;
      final y = 0.05 + _rng.nextDouble() * 0.95;
      final rxz = math.sqrt(math.max(0.0, 1.0 - y * y));
      final dir = vm.Vector3(rxz * math.cos(theta), y, rxz * math.sin(theta));
      if (!accept(dir, _rng)) continue;

      // 幂律：bigness 接近 1 的很少 → 亮星稀少。
      final bigness = math.pow(_rng.nextDouble(), 2.6).toDouble();
      // 圆盘直径 = 2 × scale（几何半径是 1.0）。目标屏幕上 3~13px：
      // fov 60° / 1200px 高时 223m 处 1m ≈ 4.7px，所以直径 0.7~2.8m
      // → scale ≈ 0.34~1.36。
      // 旧值 1.4~4.4 是**半径**缩放（直径最大 8.8m ≈ 41px），
      // 这才是"星星看起来是巨大六边菱形方块"的真正原因：
      // 20 面体在 41px 下轮廓一览无余。
      final scale = (0.34 + 1.02 * bigness) * sizeScale;

      _starMesh!.addInstance(
        vm.Matrix4.compose(
          dir * (domeRadius * 0.93),
          // 圆盘法线指向观察者。星星在 223m 外、相机只在原点附近 ±70m 活动，
          // 朝向最偏 atan(70/223) ≈ 17°（投影只扁 4%）→ 按星星方向一次算死即可，
          // 不必每帧 billboard（那是每帧 900 次矩阵写入）。
          _facingQuaternion(-dir),
          vm.Vector3(scale, scale, scale),
        ),
        color: vm.Vector4(1, 1, 1, 1),
      );

      // 星色：多数偏白，少量暖（橙）与冷（蓝）。星等带来的亮度差
      // 直接烘进基色，闪烁只在它之上做乘性波动。
      final roll = _rng.nextDouble();
      vm.Vector4 color;
      if (roll < 0.72) {
        final b = 0.86 + _rng.nextDouble() * 0.14;
        color = vm.Vector4(b, b, b, 1.0);
      } else if (roll < 0.87) {
        color = vm.Vector4(1.0, 0.86, 0.70, 1.0); // 暖星
      } else {
        color = vm.Vector4(0.72, 0.84, 1.0, 1.0); // 冷星
      }
      final bright = (0.60 + 0.40 * bigness) * brightnessScale;
      _starBaseColors.add(vm.Vector4(
        color.r * bright,
        color.g * bright,
        color.b * bright,
        1.0,
      ));
      _starTwinkleSpeed.add(1.2 + _rng.nextDouble() * 3.0);
      _starTwinklePhase.add(_rng.nextDouble() * math.pi * 2);
      // 闪烁幅度与星等挂钩：亮星闪得明显，暗星几乎不闪。
      // 幅度上限 0.34 → 相对亮度最低 0.66，不会"闪到熄灭"（实测教训）。
      _starTwinkleAmp.add(0.12 + 0.22 * bigness);
      placed++;
    }
  }

  /// 银河弥散带的几何：沿银道面大圆走一圈的带状网格，
  /// 顶点色在带的两侧渐淡（顶点 alpha = 0）→ 一条没有硬边的银河。
  MeshGeometry _buildGalaxyBandGeometry() {
    const columns = 80;
    const rows = 5;
    // 半宽（弧度弧度上的偏移量，随方向归一化，近似角度）。
    const halfWidth = 0.20;
    // 0.24：让银河"一眼认得出"。偏低（≤0.15）时它只是一层猜不透的雾，
    // 偏高（≥0.32）会盖过星星、变成一条実心的白带。
    const baseAlpha = 0.24;

    final pole = _galacticPole;
    var e1 = vm.Vector3(0, 1, 0).cross(pole);
    if (e1.length2 < 1e-6) e1 = vm.Vector3(1, 0, 0).cross(pole);
    e1.normalize();
    final e2 = pole.cross(e1).normalized();

    final b = GeometryBuilder(deduplicate: false);
    for (var i = 0; i <= columns; i++) {
      final a = math.pi * 2 * i / columns;
      final center = (e1 * math.cos(a) + e2 * math.sin(a)).normalized();
      for (var r = 0; r < rows; r++) {
        final u = (r / (rows - 1)) * 2.0 - 1.0; // -1..1
        final dir = (center + pole * (u * halfWidth)).normalized();
        // 横向高斯衰减：中间厚、两侧化开。
        final fade = math.pow(1.0 - u * u, 1.7).toDouble();
        // 沿带方向用噪声打斑：银河不是均匀的一条，有明暗团块。
        final mott =
            _noise.fbm2(center.x * 3.1 + 5.0, center.z * 3.1 - 2.0, octaves: 3) *
                    0.5 +
                0.5;
        final alpha = baseAlpha * fade * (0.45 + 0.55 * mott);
        b
          ..color(vm.Vector4(0.58, 0.65, 0.88, alpha.clamp(0.0, 1.0)))
          ..addVertex(dir * (domeRadius * 0.965));
      }
    }
    for (var i = 0; i < columns; i++) {
      for (var r = 0; r < rows - 1; r++) {
        final v0 = i * rows + r;
        final v1 = v0 + 1;
        final v2 = v0 + rows;
        final v3 = v2 + 1;
        b
          ..addTriangle(v0, v2, v1)
          ..addTriangle(v1, v2, v3);
      }
    }
    return b.build();
  }

  /// 月面球几何：手工构建球面网格，并把"明暗层次"烘进顶点色。
  ///
  /// **为什么不用 `IcosphereGeometry`**：它没有顶点色，月面只能是一圏纯色；
  /// 而原方案的"月海"是 14 个压扁的暗球贴在球面上 —— 侧看会露出台阶，
  /// 尺寸又是幂律随机的，读起来像"随手贴的圆纸片"。顶点色方案一次
  /// 解决纹理、层次与穿帮三个问题，还顺带少了 14 个节点。
  ///
  /// [viewDir] 是"从观察者指向月心"的方向（用于边缘变暗），
  /// [lightFrom] 是月光的来向（用于受光倾向）。
  MeshGeometry _buildMoonGeometry(
    double radius,
    vm.Vector3 viewDir,
    vm.Vector3 lightFrom,
  ) {
    const rings = 22;
    const segments = 34;
    final b = GeometryBuilder(deduplicate: false);

    for (var r = 0; r <= rings; r++) {
      final phi = math.pi * r / rings; // 0 = 北极
      final y = math.cos(phi);
      final sinPhi = math.sin(phi);
      for (var s = 0; s <= segments; s++) {
        final theta = math.pi * 2 * s / segments;
        final dir = vm.Vector3(
          sinPhi * math.cos(theta),
          y,
          sinPhi * math.sin(theta),
        );
        b
          ..color(_moonSurfaceColor(dir, viewDir, lightFrom))
          ..addVertex(dir * radius);
      }
    }

    for (var r = 0; r < rings; r++) {
      for (var s = 0; s < segments; s++) {
        final a = r * (segments + 1) + s;
        final c = a + segments + 1;
        b
          ..addTriangle(a, c, a + 1)
          ..addTriangle(a + 1, c, c + 1);
      }
    }
    return b.build();
  }

  /// 月面着色：把"明暗层次"烘进顶点色（四层相乘）。
  ///
  ///   1. **边缘变暗**（limb darkening）：球面正对观察者的部分最亮、
  ///      向边缘渐暗。真实的月球/大行星都有这个特征；缺了它，
  ///      月亮就是一个没有体积的白色圆盘。
  ///   2. **月海**：低频噪声的低值区压暗成**不规则**暗斑 ——
  ///      比贴圆片自然，而且永远不会有台阶穿帮。
  ///   3. **细斑**：高频噪声的微弱起伏，让月陆不是一片死板的灰。
  ///   4. **受光倾向**：朝月光来向的一侧略亮（幅度刻意很小，只给体积感，
  ///      不形成明显月牙）—— 让月亮与场景里月光的方向对得上。
  vm.Vector4 _moonSurfaceColor(
    vm.Vector3 dir,
    vm.Vector3 viewDir,
    vm.Vector3 lightFrom,
  ) {
    // 1) 边缘变暗：正对观察者 1.0 → 边缘 0.52。
    //    指数 0.42 < 1：暗得集中在最外圈，避免整个月面发灰。
    final facing = dir.dot(viewDir).clamp(0.0, 1.0);
    final limb = 0.52 + 0.48 * math.pow(facing, 0.42).toDouble();

    // 2) 月海：低频噪声映射到 0.62（暗）~1.0（月陆）。
    final mareN =
        _noise.fbm2(dir.x * 1.45 + 31.0, dir.z * 1.45 - 19.0, octaves: 2);
    final mareT = ((mareN + 0.30) / 0.42).clamp(0.0, 1.0);
    final mare = 0.62 + 0.38 * mareT;

    // 3) 细斑：±6% 的起伏。
    final mottle = 1.0 +
        _noise.fbm2(dir.x * 4.1 - 7.0, dir.z * 4.1 + 23.0, octaves: 3) * 0.06;

    // 4) 受光倾向：亮侧 +8%。
    final lit = 0.92 + 0.08 * (dir.dot(lightFrom) * 0.5 + 0.5);

    final v = (limb * mare * mottle * lit).clamp(0.0, 1.0);
    // 略偏暖：真实的月光是暖白的（蓝是因为夜景里人眼适应，不是光本身）。
    return vm.Vector4(v, v * 0.995, v * 0.975, 1.0);
  }

  /// 月晕的几何：XY 平面上的圆盘，顶点 alpha 从中心向边缘衰减。
  /// 使用时把节点 +Z 对齐相机（[_facingQuaternion]）即成为 billboard。
  MeshGeometry _buildGlowDiscGeometry() {
    const rings = 8;
    const segments = 28;
    final b = GeometryBuilder(deduplicate: false);

    b
      ..color(vm.Vector4(1, 1, 1, 0.55))
      ..addVertex(vm.Vector3.zero());
    for (var r = 1; r <= rings; r++) {
      final t = r / rings;
      // 幂次越高，亮心越小、光晕越柔。
      final alpha = math.pow(1.0 - t, 2.6) * 0.55;
      for (var s = 0; s <= segments; s++) {
        final a = math.pi * 2 * s / segments;
        b
          ..color(vm.Vector4(1, 1, 1, alpha))
          ..addVertex(vm.Vector3(math.cos(a) * t, math.sin(a) * t, 0));
      }
    }
    // 内圈扇形。
    for (var s = 0; s < segments; s++) {
      b.addTriangle(0, 1 + s, 1 + s + 1);
    }
    // 各环之间的四边形。
    for (var r = 1; r < rings; r++) {
      final inner = 1 + (r - 1) * (segments + 1);
      final outer = 1 + r * (segments + 1);
      for (var s = 0; s < segments; s++) {
        b
          ..addTriangle(inner + s, outer + s, inner + s + 1)
          ..addTriangle(inner + s + 1, outer + s, outer + s + 1);
      }
    }
    return b.build();
  }

  // ------------------------------------------------------------------
  // 雨幕
  // ------------------------------------------------------------------

  void _tickRain(double dt, vm.Vector3 origin, vm.Vector3? cameraPos, double amount) {
    final mesh = _rainMesh;
    if (mesh == null) return;
    final visible = amount > 0.02;
    if (visible != _rainVisible) {
      _rainVisible = visible;
      if (!visible) {
        // 隐藏全部实例：零缩放，不是零矩阵。
        for (var i = 0; i < _rainCount; i++) {
          mesh.setInstanceTransform(i, _hiddenTransform);
        }
      }
    }

    if (!visible) return;

    // 雨势影响落速：大雨"砸"，小雨"飘"；阵风再叠一层快慢起伏。
    final speedScale = (0.85 + 0.35 * amount) * (0.92 + 0.16 * _gust);
    // 阵风大时雨丝略微拉长，读成"斜着抽下来"。
    final streakGust = 0.86 + 0.30 * _gust;
    final half = _rainFieldSize * 0.5;
    final alphaScale = 0.72 + 0.28 * amount;

    // 雨幕跟着角色走：把雨滴撒在角色周围的柱体内循环落下。
    final active = (amount * _rainCount).round();
    for (var i = 0; i < _rainCount; i++) {
      if (i >= active) {
        mesh.setInstanceTransform(i, _hiddenTransform);
        continue;
      }
      final p = _rainDrops[i];

      // 风偏与下落用同一组速度，保证"斜落"与"斜丝"朝向一致；
      // 水平速度再乘每滴自己的漂移系数 → 雨丝的斜度有细微差异，
      // 不会整片雨幕像一个刚性网格在平移。
      final windX = _rainWindSpeed * _rainDriftX[i] * dt;
      final fallY = _rainFallSpeed * speedScale * _rainSpeedJitter[i] * dt;
      p.y -= fallY;
      p.x += windX;

      // 风偏靠环绕回收，而不是无限累加（否则雨滴全被吹到界外）。
      // **X 与 Z 都要环绕**：只回收 X 时玩家沿 Z 跑动会把雨幕甩在身后，
      // 跑出雨柱范围后就只剩"身边一小片雨"（实测隐患）。
      final relX = p.x - origin.x;
      if (relX > half) {
        p.x -= _rainFieldSize;
      } else if (relX < -half) {
        p.x += _rainFieldSize;
      }
      final relZ = p.z - origin.z;
      if (relZ > half) {
        p.z -= _rainFieldSize;
      } else if (relZ < -half) {
        p.z += _rainFieldSize;
      }

      if (p.y < origin.y - _rainGroundSlack) {
        // 落地 → 重生到头顶；顺便在落点溅一朵水花。
        _maybeSpawnSplash(p.x, p.z, origin);
        p.y = origin.y + _rainColumnTop + _rng.nextDouble() * 6.0;
        p.x = origin.x + (_rng.nextDouble() - 0.5) * _rainFieldSize;
        p.z = origin.z + (_rng.nextDouble() - 0.5) * _rainFieldSize;
      }

      // 雨丝的朝向由它**自己的速度矢量**构造（斜着位移配斜着拉长的丝）。
      final velocity = vm.Vector3(windX, -fallY, 0);
      final tilt = velocity.length2 < 1e-12
          ? 0.0
          : math.atan2(velocity.x, -velocity.y);

      final dx0 = p.x - origin.x;
      final dz0 = p.z - origin.z;
      final dist = math.sqrt(dx0 * dx0 + dz0 * dz0);

      // 到相机的真实距离（屏幕上的像素大小取决于它）。
      final camDist = cameraPos == null ? dist : (p - cameraPos).length;

      // 近景压细：越近越细，贴脸的直接隐藏。
      final nearFade = ((camDist - _rainNearFadeEnd) /
              (_rainNearFadeStart - _rainNearFadeEnd))
          .clamp(0.0, 1.0);
      if (nearFade <= 0.001) {
        mesh.setInstanceTransform(i, _hiddenTransform);
        continue;
      }

      final width = _widthForDistance(camDist);
      // 丝长随落速变化：快滴拖得更长（同一帧内位移更大）。
      final length = _rainStreakBase *
          _rainLengthJitter[i] *
          streakGust *
          (camDist / 8.5).clamp(0.35, 6.0);

      mesh.setInstanceTransform(
        i,
        vm.Matrix4.compose(
          p,
          vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), tilt),
          vm.Vector3(width, length, width),
        ),
      );

      // 近浓远淡：深度用了平方，远处衰减比线性快，
      // 雨幕因此有"贴着玩家的一层"与"远景灰噪"两个层次。
      final norm = (dist / (_rainFieldSize * 0.5)).clamp(0.0, 1.0);
      final depth = 1.0 - norm;
      _rainFade[i] = (0.32 + 0.68 * depth * depth) * (0.35 + 0.65 * nearFade);
      mesh.setInstanceColor(
        i,
        vm.Vector4(
          _rainColor.r,
          _rainColor.g,
          _rainColor.b,
          _rainColor.a * _rainFade[i] * alphaScale,
        ),
      );
    }
  }

  /// 低频、低调的闪电。
  ///
  /// 设计取舍：**稀有 + 不刺眼**。频繁的强闪会把卡通画面搅成恐怖片，
  /// 也干扰玩法；这里做成 16–38 秒一次、峰值增亮约 3.6 倍的柔和双脉冲，
  /// 目标是"感觉到天在亮一下"，而不是"闪光弹"。
  void _tickLightning(double dt, double amount) {
    // 只有接近满雨量才可能有闪电；淡入淡出期间不闪。
    if (amount <= 0.75) {
      if (_flash != 0 || _lightningTimer > 0) {
        _flash = 0;
        _lightningTimer = 0;
      }
      // 恢复到天气档的基准值（每帧写四个 Vector3 开销可忽略）。
      _sunLight.intensity = _baseSunIntensity;
      _applySkyColors(1.0);
      _rainMaterial?.baseColorFactor = _rainColor;
      return;
    }

    if (_lightningTimer <= 0) {
      _lightningCool -= dt;
      if (_lightningCool <= 0) {
        _lightningDuration = 0.30 + _rng.nextDouble() * 0.25;
        _lightningTimer = _lightningDuration;
        _lightningCool = 16.0 + _rng.nextDouble() * 22.0;
      }
    }

    if (_lightningTimer > 0) {
      _lightningTimer -= dt;
      final t =
          (1.0 - (_lightningTimer / _lightningDuration)).clamp(0.0, 1.0);
      // 主闪：指数衰减；次闪：0.38 处的较弱回光 ——
      // 真实的云闪多是"一下，再一下"，单脉冲看着像相机闪光灯。
      final a = math.exp(-t * 24);
      final b = 0.45 * math.exp(-(t - 0.38).abs() * 30);
      _flash = (a + b).clamp(0.0, 1.0);
    } else {
      _flash = 0;
    }

    // 三处联动：平行光、天空盒、雨丝材质。
    // 缺任何一处都会露馅（光变亮但雨丝还是暗的，一眼假）。
    _sunLight.intensity = _baseSunIntensity * (1.0 + _flash * 3.6);
    // 天空盒整体提亮：闪电是"整个天被照亮"，只抬平行光会读成
    // 光从地面打上来（实测很假）；提亮同时保留天色本身的色调差。
    _applySkyColors(1.0 + _flash * 2.2);
    _rainMaterial?.baseColorFactor = vm.Vector4(
      _lerp(_rainColor.r, _rainFlashColor.r, _flash),
      _lerp(_rainColor.g, _rainFlashColor.g, _flash),
      _lerp(_rainColor.b, _rainFlashColor.b, _flash),
      _lerp(_rainColor.a, _rainFlashColor.a, _flash),
    );
  }

  InstancedMesh _buildRain() {
    // 材质引用留一份：闪电要做瞬间增亮。
    _rainMaterial = UnlitMaterial()
      ..baseColorFactor = _rainColor
      // **必须显式设为 blend**：默认 opaque 会完全忽略 alpha 通道。
      ..alphaMode = AlphaMode.blend
      ..doubleSided = true;
    final mesh = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3(1, 1, 1)),
      material: _rainMaterial!,
    );
    for (var i = 0; i < _rainCount; i++) {
      _rainDrops.add(vm.Vector3(
        (_rng.nextDouble() - 0.5) * _rainFieldSize,
        _rng.nextDouble() * _rainColumnTop,
        (_rng.nextDouble() - 0.5) * _rainFieldSize,
      ));
      _rainLengthJitter.add(0.65 + _rng.nextDouble() * 0.85);
      _rainSpeedJitter.add(0.85 + _rng.nextDouble() * 0.40);
      // 漂移系数跨过 1.0：一部分雨丝几乎竖直，一部分明显斜一点。
      _rainDriftX.add(0.72 + _rng.nextDouble() * 0.62);
      _rainFade.add(1.0);
      mesh.addInstance(_hiddenTransform);
    }
    return mesh;
  }

  // ------------------------------------------------------------------
  // 水花
  // ------------------------------------------------------------------

  /// 水花几何：贴地的**实心水环**（内缘淡 → 中段亮环 → 外缘透明）。
  ///
  /// 比原来的空心圆环多两层：中段的亮环给出"水被砸起来一圈"的实体感，
  /// 外缘淡出避免硬边，内缘半透明让水花不像一个塑料圈。
  MeshGeometry _splashGeometry() {
    final b = GeometryBuilder(deduplicate: false);
    const segments = 14;
    // 半径层 + 对应顶点 alpha。
    const radii = <double>[0.24, 0.50, 0.74, 1.0];
    const alphas = <double>[0.45, 0.72, 1.0, 0.0];
    const layers = 4;
    for (var s = 0; s <= segments; s++) {
      final a = math.pi * 2 * s / segments;
      final cosA = math.cos(a);
      final sinA = math.sin(a);
      for (var r = 0; r < layers; r++) {
        b
          ..color(vm.Vector4(1, 1, 1, alphas[r]))
          ..addVertex(vm.Vector3(cosA * radii[r], 0, sinA * radii[r]));
      }
    }
    for (var s = 0; s < segments; s++) {
      final base = s * layers;
      final next = base + layers;
      for (var r = 0; r < layers - 1; r++) {
        b
          ..addTriangle(base + r, next + r, base + r + 1)
          ..addTriangle(base + r + 1, next + r, next + r + 1);
      }
    }
    return b.build();
  }

  InstancedMesh _buildSplashPool() {
    final mesh = InstancedMesh(
      geometry: _splashGeometry(),
      material: UnlitMaterial()
        ..baseColorFactor = vm.Vector4(0.88, 0.94, 1.00, 1.0)
        ..alphaMode = AlphaMode.blend
        ..doubleSided = true,
    );
    for (var i = 0; i < _splashPool; i++) {
      _splashPos.add(vm.Vector3.zero());
      _splashAge.add(0);
      _splashLife.add(1);
      _splashScale.add(1);
      _splashActive.add(false);
      mesh.addInstance(_hiddenTransform);
    }
    return mesh;
  }

  /// 在落点尝试生成一朵水花（雨滴落地时调用）。
  void _maybeSpawnSplash(double x, double z, vm.Vector3 origin) {
    if (_rng.nextDouble() > 0.22 * current.rainAmount) return; // 控制密度
    final pool = _splashMesh;
    if (pool == null) return;

    // 从光标处找一个空闲槽（环形复用，最老的先被覆盖）。
    for (var n = 0; n < _splashPool; n++) {
      final idx = _splashCursor = (_splashCursor + 1) % _splashPool;
      if (!_splashActive[idx]) {
        final groundY = terrain.heightAt(x, z);
        if (groundY < origin.y - 6.0) return; // 太深的谷底不溅（看不见）
        _splashActive[idx] = true;
        // 抬高 5cm：贴地会被草叶完全挡住（实测），略高于草根才看得见。
        _splashPos[idx] = vm.Vector3(x, groundY + 0.05, z);
        _splashAge[idx] = 0;
        _splashLife[idx] = 0.38 + _rng.nextDouble() * 0.30;
        _splashScale[idx] = 0.50 + _rng.nextDouble() * 0.90;
        return;
      }
    }
  }

  void _tickSplashes(double dt, vm.Vector3 origin, double amount) {
    final mesh = _splashMesh;
    if (mesh == null) return;
    if (amount <= 0.02) {
      // 雨停：清空所有水花（有存活的才需要写一遍隐藏）。
      var anyActive = false;
      for (final a in _splashActive) {
        if (a) {
          anyActive = true;
          break;
        }
      }
      if (anyActive) {
        for (var i = 0; i < _splashPool; i++) {
          _splashActive[i] = false;
          mesh.setInstanceTransform(i, _hiddenTransform);
        }
      }
      return;
    }

    // 即使没有雨滴落地事件，也按雨量持续补一些水花（保证视觉密度）。
    // 52 个/秒：配合 150 的池容量，近场能同时看到十几朵水花在扩散，
    // 这是"雨砸在地上"与"几滴雨在溅"的分界线。
    _splashSpawnAccumulator += dt * 52 * amount;
    while (_splashSpawnAccumulator >= 1.0) {
      _splashSpawnAccumulator -= 1.0;
      final a = _rng.nextDouble() * math.pi * 2;
      final r = 1.5 + _rng.nextDouble() * 13.0;
      _maybeSpawnSplash(
        origin.x + math.cos(a) * r,
        origin.z + math.sin(a) * r,
        origin,
      );
    }

    for (var i = 0; i < _splashPool; i++) {
      if (!_splashActive[i]) continue;
      _splashAge[i] += dt;
      final t = _splashAge[i] / _splashLife[i];
      if (t >= 1.0) {
        _splashActive[i] = false;
        mesh.setInstanceTransform(i, _hiddenTransform);
        continue;
      }
      // 水环扩散 + 淡出：前 35% 快速扩张，之后主要靠透明度衰减。
      final grow = (t / 0.35).clamp(0.0, 1.0);
      final scale = _splashScale[i] * (0.30 + 0.70 * grow);
      final alpha = (1.0 - t) * 0.85 * amount;
      mesh.setInstanceTransform(
        i,
        vm.Matrix4.compose(
          _splashPos[i],
          vm.Quaternion.identity(),
          vm.Vector3(scale, 1.0, scale),
        ),
      );
      mesh.setInstanceColor(
        i,
        vm.Vector4(0.88, 0.94, 1.00, alpha.clamp(0.0, 1.0)),
      );
    }
  }

  // ------------------------------------------------------------------
  // 积水
  // ------------------------------------------------------------------

  /// 地面积水：只放在**平坦**、**不在河道里**且**草稀疏**的地方 ——
  /// 坡地上放圆盘会切进地形；密草里的水洼完全看不见（实测）。
  InstancedMesh _buildPuddles() {
    final mesh = InstancedMesh(
      geometry: CylinderGeometry(
        topRadius: 0.5,
        bottomRadius: 0.52,
        height: 0.02,
        radialSegments: 12,
      ),
      material: UnlitMaterial()
        ..baseColorFactor = vm.Vector4(0.55, 0.62, 0.72, 0.0)
        ..alphaMode = AlphaMode.blend
        ..doubleSided = true,
    );

    var placed = 0;
    var attempts = 0;
    while (placed < _puddleCount && attempts < _puddleCount * 40) {
      attempts++;
      final a = _rng.nextDouble() * math.pi * 2;
      final r = 6.0 + _rng.nextDouble() * 44.0;
      final x = math.cos(a) * r;
      final z = math.sin(a) * r;

      if (terrain.slopeAt(x, z) > 0.10) continue;
      final y = terrain.heightAt(x, z);
      if (y - terrain.waterSurfaceAt(x, z) < 0.8) continue; // 别放河里/滩上

      // 选址偏好"草稀疏"的地方：与地表配色/草密度同一张 patch 噪声，
      // 噪声低 = 草稀 = 有裸地。
      if (_noise.fbm2(x * 0.075 + 11.0, z * 0.075 + 29.0, octaves: 2) > 0.0) {
        continue;
      }

      final scale = 1.2 + _rng.nextDouble() * 2.0;
      final elong = 0.65 + _rng.nextDouble() * 0.6;
      mesh.addInstance(
        vm.Matrix4.compose(
          vm.Vector3(x, y + 0.045, z),
          vm.Quaternion.axisAngle(
              vm.Vector3(0, 1, 0), _rng.nextDouble() * math.pi * 2),
          vm.Vector3(scale, 1.0, scale * elong),
        ),
        // 反光天色：真实的积水洼首先是"映着天空的亮斑"，其次才是深色。
        color: vm.Vector4(0.55, 0.62, 0.72, 0.0),
      );
      // 存下落点：涟漪只能长在水面上，必须知道水在哪里。
      // 世界半径 = 几何半径(0.5) × 缩放；取短轴，保证涟漪不溢出水面。
      _puddleSpots.add(vm.Vector3(x, y + 0.045, z));
      _puddleScale.add(0.5 * scale * math.min(1.0, elong));
      placed++;
    }
    return mesh;
  }

  void _tickPuddles(double amount, double time) {
    final mesh = _puddleMesh;
    final node = _puddleNode;
    if (mesh == null || node == null) return;

    final visible = amount > 0.02;
    if (visible != _puddleVisible) {
      _puddleVisible = visible;
      node.scale = visible ? vm.Vector3(1, 1, 1) : vm.Vector3.zero();
    }
    if (!visible) return;

    // 积水随雨量淡入淡出：alpha 上限 0.50 —— 太实会像"贴了蓝片"，
    // 太淡则雨势最强时也看不出地面积了水。
    final alpha = 0.50 * amount;
    for (var i = 0; i < _puddleSpots.length; i++) {
      // 每片水面的反光强度做很慢的相位漂移：72 个圆盘"一起呼吸"会很像
      // 某种 UI 特效，错开相位才像自然反光。
      final shimmer = 0.86 + 0.14 * math.sin(time * 0.7 + i * 1.7);
      mesh.setInstanceColor(
        i,
        vm.Vector4(0.55, 0.62, 0.72, (alpha * shimmer).clamp(0.0, 1.0)),
      );
    }
  }

  // ------------------------------------------------------------------
  // 积水涟漪
  // ------------------------------------------------------------------

  InstancedMesh _buildRipplePool() {
    final mesh = InstancedMesh(
      geometry: _splashGeometry(),
      material: UnlitMaterial()
        ..baseColorFactor = vm.Vector4(0.72, 0.82, 0.95, 0.0)
        ..alphaMode = AlphaMode.blend
        ..doubleSided = true,
    );
    for (var i = 0; i < _ripplePool; i++) {
      _ripplePos.add(vm.Vector3.zero());
      _rippleAge.add(0);
      _rippleLife.add(1);
      _rippleScale.add(1);
      _rippleActive.add(false);
      mesh.addInstance(_hiddenTransform);
    }
    return mesh;
  }

  void _tickRipples(double dt, vm.Vector3 origin, double amount) {
    final mesh = _rippleMesh;
    if (mesh == null) return;

    if (amount <= 0.02 || _puddleSpots.isEmpty) {
      var anyActive = false;
      for (final a in _rippleActive) {
        if (a) {
          anyActive = true;
          break;
        }
      }
      if (anyActive) {
        for (var i = 0; i < _ripplePool; i++) {
          _rippleActive[i] = false;
          mesh.setInstanceTransform(i, _hiddenTransform);
        }
      }
      return;
    }

    // 生成速率随雨量：40 个/秒 满雨。涟漪寿命长（0.9–1.6s），
    // 所以这个速率下会同时存在 40–60 圈，铺满近场的水面。
    _rippleAccumulator += dt * 40 * amount;
    while (_rippleAccumulator >= 1.0) {
      _rippleAccumulator -= 1.0;
      _spawnRipple(origin);
    }

    for (var i = 0; i < _ripplePool; i++) {
      if (!_rippleActive[i]) continue;
      _rippleAge[i] += dt;
      final t = _rippleAge[i] / _rippleLife[i];
      if (t >= 1.0) {
        _rippleActive[i] = false;
        mesh.setInstanceTransform(i, _hiddenTransform);
        continue;
      }
      // 水面的波是等速扩散的（不同于水花的"先快后慢"）。
      final scale = _rippleScale[i] * (0.22 + 0.78 * t);
      // alpha 用平方衰减：涟漪的淡出比水花快，避免水面糊成一片白。
      final alpha = (1.0 - t) * (1.0 - t) * 0.55 * amount;
      mesh.setInstanceTransform(
        i,
        vm.Matrix4.compose(
          _ripplePos[i],
          vm.Quaternion.identity(),
          vm.Vector3(scale, 1.0, scale),
        ),
      );
      mesh.setInstanceColor(
        i,
        vm.Vector4(0.72, 0.82, 0.95, alpha.clamp(0.0, 1.0)),
      );
    }
  }

  void _spawnRipple(vm.Vector3 origin) {
    // 随机挑一片积水，在它的范围内随机一点（半径开根号 → 面积均匀）。
    final spot = _rng.nextInt(_puddleSpots.length);
    final center = _puddleSpots[spot];
    // 只对玩家附近的积水生成：远处的涟漪看不见，白算。
    final ddx = center.x - origin.x;
    final ddz = center.z - origin.z;
    if (ddx * ddx + ddz * ddz > 26.0 * 26.0) return;

    final a = _rng.nextDouble() * math.pi * 2;
    final r = math.sqrt(_rng.nextDouble()) * _puddleScale[spot];
    final x = center.x + math.cos(a) * r;
    final z = center.z + math.sin(a) * r;

    for (var n = 0; n < _ripplePool; n++) {
      final idx = _rippleCursor = (_rippleCursor + 1) % _ripplePool;
      if (!_rippleActive[idx]) {
        _rippleActive[idx] = true;
        // 抬 2cm：与水面同高时会被 z-fighting 闪成条纹。
        _ripplePos[idx] = vm.Vector3(x, center.y + 0.02, z);
        _rippleAge[idx] = 0;
        _rippleLife[idx] = 0.9 + _rng.nextDouble() * 0.7;
        // 最大半径控制在积水盘以内（积水半径约 0.4–1.4m），
        // 否则涟漪会扩到干地上，一眼就看出"贴错了"。
        _rippleScale[idx] = 0.35 + _rng.nextDouble() * 0.50;
        return;
      }
    }
  }

  // ------------------------------------------------------------------
  // 参数下发与插值
  // ------------------------------------------------------------------

  void _commit(WeatherProfile p) {
    // 天空的三条驱动量：夜量（压暗）、浑浊度（去饱和）、太阳方向（日盘）。
    // 全部天气驱动，所以切天气时天色随 _interpolate 一起插值。
    final night = p.nightAmount;
    final haze = (p.skyTurbidity / 14.0).clamp(0.0, 1.0);
    // 引擎天空盒（`GradientSkySource`）：三个色 + HDR 太阳盘。
    // 三色走「浑浊度去饱和 + 夜色压暗」同一套逻辑，
    // 所以天空、雾、云三者切天气时不会各说各话。
    //
    // 存成基准值（不直接写进 _skySource）是因为闪电要在它之上做瞬间
    // 增亮（见 [_applySkyColors]）—— 直接改 _skySource 会把基准吃掉。
    final grey = haze * (1.0 - night);
    // 天空整体亮度 = 「天光还剩多少」（`skyEnergy`：晴 1.0 / 阴 0.62 / 雨 0.30）
    // × 夜色压暗。
    //
    // **`skyEnergy` 必须在这里用上**：它是天气档里描述"云层遮阳后天上还剩
    // 多少光"的量。只靠浑浊度去饱和的话，晴/阴/雨三种天空的**亮度几乎一样**
    // （实测均值 196 / 193 / 188），只是色调略不同 —— 看上去像同一天空换了滤镜，
    // 而且天空太亮时会**把云吃掉**：白云（亮度 220~240）贴在 200 的天空上，
    // 几乎看不出云形。压暗天空后云才有对比。
    final dn = p.skyEnergy * (1.0 - 0.90 * night);
    final zenC = _lerp3(_skyZenith, _skyHaze, grey * 0.55);
    final horC = _lerp3(_skyHorizon, _skyHaze, grey * 0.85);
    final gndC = _lerp3(_skyGround, _skyHaze, grey * 0.30);
    // 夜色不是"变黑"而是"变深蓝"：蓝通道刻意少压一点。
    _baseZenith =
        vm.Vector3(zenC.x * dn, zenC.y * dn * 1.06, zenC.z * dn * 1.18);
    _baseHorizon = vm.Vector3(
        horC.x * dn * 1.04, horC.y * dn * 1.06, horC.z * dn * 1.14);
    _baseGround =
        vm.Vector3(gndC.x * dn, gndC.y * dn, gndC.z * dn * 1.10);
    // 太阳盘亮度直接由平行光强度折算 —— 太阳亮、场景就亮，两者天然一致。
    _baseSunDisk = vm.Vector3(
      p.lightColor.x * p.sunIntensity * 0.85,
      p.lightColor.y * p.sunIntensity * 0.85,
      p.lightColor.z * p.sunIntensity * 0.85,
    );
    _skySource.sunDirection = p.sunToward;
    _applySkyColors(1.0);

    // 平行光：与可见太阳解耦（见 WeatherProfile 注释）——
    // 白天跟太阳走，夜晚从月亮位置照下来。
    _baseSunIntensity = p.sunIntensity;
    _sunLight
      ..intensity = _baseSunIntensity
      ..direction = p.lightTravel
      ..color = p.lightColor;

    // 云：颜色随天气（白 / 铅灰 / 深蓝夜云），云量经由"逐团阈值"
    // 决定哪些云团出现（见 [_cloudInstanceColor]），而不是整层淡出。
    // 实际颜色在 [_tickClouds] 里算，这里只更新输入并把实例色标脏。
    _cloudTint = p.cloudColor;
    _cloudCover = p.cloudCoverage;
    final sd = p.sunToward;
    final sl = math.sqrt(sd.x * sd.x + sd.z * sd.z);
    if (sl > 1e-4) _sunAzimuth = vm.Vector3(sd.x / sl, 0, sd.z / sl);
    _cloudDirty = true;

    // 谷雾体积：**除雾以外的字段同步当前天气**，而雾浓度由天气档自己的
    // `fogDensity` 推出来（硬编码会让天气档里的值对这个体积完全失效，
    // 变成"谷雾永远一个浓度"）。体积内的雾本就该比全局雾浓：
    // 它是"河谷里额外那一层"。
    // 同步是为了让进出河谷的过渡不跳变：体积里残留上一档天气的曝光/环境光
    // 时，切天气的瞬间会在谷内明显看到一次明暗跳。
    final v = _mistVolume?.settings;
    if (v != null) _applyMistFog(v, p);
    _mistVolume?.weight = p.valleyMist;
  }

  WeatherProfile _interpolate(WeatherProfile a, WeatherProfile b, double t) {
    if (t >= 1.0) return b;
    return WeatherProfile(
      skyTint: _lerp4(a.skyTint, b.skyTint, t),
      sunIntensity: _lerp(a.sunIntensity, b.sunIntensity, t),
      sunToward: _lerp3(a.sunToward, b.sunToward, t),
      lightTravel: _lerp3(a.lightTravel, b.lightTravel, t),
      lightColor: _lerp3(a.lightColor, b.lightColor, t),
      skyTurbidity: _lerp(a.skyTurbidity, b.skyTurbidity, t),
      skyMie: _lerp(a.skyMie, b.skyMie, t),
      skyEnergy: _lerp(a.skyEnergy, b.skyEnergy, t),
      cloudColor: _lerp3(a.cloudColor, b.cloudColor, t),
      cloudCoverage: _lerp(a.cloudCoverage, b.cloudCoverage, t),
      valleyMist: _lerp(a.valleyMist, b.valleyMist, t),
      nightAmount: _lerp(a.nightAmount, b.nightAmount, t),
      grassWind: _lerp(a.grassWind, b.grassWind, t),
      environmentIntensity:
          _lerp(a.environmentIntensity, b.environmentIntensity, t),
      exposure: _lerp(a.exposure, b.exposure, t),
      fogDensity: _lerp(a.fogDensity, b.fogDensity, t),
      rainAmount: _lerp(a.rainAmount, b.rainAmount, t),
      // 布尔参数在过渡中点切换（过渡只有 1.7s，无需平滑）。
      lensFlare: t < 0.5 ? a.lensFlare : b.lensFlare,
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static vm.Vector3 _lerp3(vm.Vector3 a, vm.Vector3 b, double t) =>
      vm.Vector3(_lerp(a.x, b.x, t), _lerp(a.y, b.y, t), _lerp(a.z, b.z, t));

  static vm.Vector4 _lerp4(vm.Vector4 a, vm.Vector4 b, double t) => vm.Vector4(
        _lerp(a.r, b.r, t),
        _lerp(a.g, b.g, t),
        _lerp(a.b, b.b, t),
        _lerp(a.a, b.a, t),
      );
}

/// 一层云的全部状态。
///
/// 把「实例网格 + 承载旋转的节点 + 漂移速度 + 每团的染色资料」打包在一起，
/// 而不是在 [SkySystem] 里摊成 `_cloudHigh` / `_cloudMatHigh` / `_cloudYawHigh`
/// 三组平行字段：三层云就是三倍的字段，加一层要改四五处、漏一处就是
/// 「某层云不动」这种很难看出来的 bug。有了这个类，增删层只改 build 里一次。
class _CloudBand {
  _CloudBand({
    required this.mesh,
    required this.node,
    required this.drift,
    required this.baseAlpha,
  });

  /// 这一层的实例网格。实例矩阵在构建后**不再改动**（漂移靠节点旋转）。
  final InstancedMesh mesh;

  /// 承载整层旋转的节点。
  final Node node;

  /// 漂移角速度（rad/s）。三层各不相同 → 视差。
  final double drift;

  /// 这一层的基础不透明度：高层薄（卷云），低层厚（积云）。
  final double baseAlpha;

  /// 当前累计漂移角（rad）。
  double yaw = 0;

  /// 每个云泡实例的**世界**位置，用于日照侧染色。
  /// 注意存的是构建时的坐标：整层绕 Y 轴旋转后方位会变，但
  /// 「云团大致在东南还是西北」这种判断不需要精确到度。
  final List<vm.Vector3> spots = [];

  /// 每个云泡实例的「出现阈值」0–1（同一云团内的云泡共享同一个值，
  /// 这样整团云是同时长出来 / 同时散掉的）。
  final List<double> thresholds = [];
}
