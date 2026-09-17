/// KirbyScene 的关卡世界：按 flutter_scene `idioms` skill 的建议，
/// 用一个普通的 Dart `Game` 类持有 [Scene] 与全部游戏状态，
/// 场景组装和每帧 tick 都从这里路由出去。
///
/// 之所以选 imperative（保留式场景图）而不是 declarative widget 写法：
/// 本关卡有程序化生成、有角色在跑、还有逐帧状态（天气过渡、收集、风摆），
/// skill 明确说这类情况"任意一条都意味着 imperative"。
///
/// 设计上刻意把"阶段一能玩"和"后续扩展"分开：
///   - 关卡内容（收集目标）由 [_spawnPickups] 单独负责，加玩法只需在这里加新实体；
///   - 每帧逻辑集中在 [tick]，各系统（天空/草地/角色）自治，互不侵入；
///   - 天气、外观、相机都有独立入口，MCP 通过 [bridgeCommand] 调同一批入口。
///
/// 实现 [BridgeTarget] 让宿主进程（ZCode / WorkBuddy 的 MCP 客户端）能读写本世界：
/// Web 通道下由 `window.kirbyMcp` 经 CDP 转发进来，桌面通道下由进程内服务器直连。

library;
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../audio/audio.dart';
import '../mcp/bridge.dart';
import 'aquatic_fauna.dart';
import 'aquatic_flora.dart';
import 'flora.dart';
import 'grass.dart';
import 'input.dart';
import 'kirby.dart';
import 'look.dart';
import 'player_controller.dart';
import 'sky.dart';
import 'terrain.dart';
import 'water.dart';

/// 一个可收集的星核。
class Pickup {
  Pickup(this.node, this.baseHeight, this.phase);

  final Node node;
  final double baseHeight;
  final double phase;
  bool collected = false;
}

class KirbyWorld implements BridgeTarget {
  KirbyWorld({int seed = 20260914});

  /// 惰性构造：`Scene()` 的构造函数会**立刻**去取 Flutter GPU 上下文
  /// （`flutter_gpu` 的 `gpuContext` 是同步初始化的），所以写成字段初始化
  /// 会让 `KirbyWorld()` 在没有 GPU 的环境里直接抛
  /// "Flutter GPU requires the Impeller rendering backend"。
  ///
  /// 这会把整条桥接命令分发的纯逻辑一起拖成不可测——所以推迟到首次访问
  /// （即 `initialize()` / 渲染）再建，测试里就能单独验证命令分发了。
  late final Scene scene = Scene();
  final GameInput input = GameInput();

  late final Terrain terrain = Terrain(seed: 20260914);

  /// 草地 v2.3：预算制 + 密度场采样 + 近场增强。11 万根（约 66 万三角，
  /// 单次 draw call）。macOS/Metal 实测见 MEMORY.md（风摆频率 12Hz、
  /// 只作用于 20m 内子集，是控制 CPU 的两个旋钮）。
  late final GrassField grass = GrassField(terrain: terrain, maxBlades: 110000);

  /// 河流的水面（按真实岸线裁剪的带状网格，CPU 驱动涟漪与水流条纹）。
  late final WaterSurface water = WaterSurface(terrain: terrain);

  /// 河床水草（沉水植物）。与水面**共用同一个** `RiverFlow` —— 于是水草倒向、
  /// 波纹推进、鱼虾游动读的是同一条河的水动力，不会各说各话。
  late final AquaticFlora aquatic =
      AquaticFlora(terrain: terrain, flow: water.flow);

  /// 鱼群与虾：水里会自己动的那一层（惊逃、跃出、弹射）。
  late final AquaticFauna fauna =
      AquaticFauna(terrain: terrain, flow: water.flow);

  /// 音频门面（见 `lib/audio/`）。波形全部程序化合成（零音频资产）：河流层的
  /// 参数来自 `RiverFlow` —— 「这条河多急」在听觉与视觉上是同一个数；
  /// 雨/风/夜三层由天气驱动，各自独立启停与淡入淡出。
  late final AudioManager audio =
      AudioManager(terrain: terrain, flow: water.flow);

  /// 分层植被：花草 / 灌木 / 乔木（阔叶 + 针叶）/ 石块。
  /// 每类一个 InstancedMesh（一次 draw call），全部静态 —— 每帧更新实例
  /// 矩阵会触发引擎重打包整块实例缓冲，那份预算留给草的风摆更划算。
  late final FloraSystem flora = FloraSystem(terrain: terrain);
  late final SkySystem sky = SkySystem(terrain: terrain);

  late final Node player;
  late final PlayerController controller;

  final List<Pickup> pickups = [];
  int score = 0;

  /// 自动演示驾驶开关。
  ///
  /// 用途是**验证循环**：无头 / 远程环境没法真的按键，但可以通过虚拟输入
  /// 走同一条游戏逻辑路径，确认角色能跑、能跳、能吃到星核。
  /// 现在由世界自己持有（而不是放在页面里），这样 MCP 也能远程开关它。
  bool demoDriving = false;
  int _demoJumpCycle = -1;

  double _time = 0;
  int _frame = 0;

  /// 上一次向宿主通道推送状态快照的时间。
  ///
  /// **不能每帧推**：快照里含着音频诊断，而它的构造要经 FFI 抢 SoLoud 的
  /// 全局音频锁（见 `lib/audio/engine.dart` 里 `outputLevel` 的注释）——
  /// 每帧推 = 每帧跟混音线程抢一次锁 = 主线程被饿住、按键几十秒没反应。
  /// 详细根因与证据链见 `_publishState`。
  double _statePublishedAt = -1;
  bool _ready = false;

  bool get isReady => _ready;
  bool get cleared => pickups.isNotEmpty && score >= pickups.length;
  String get weatherLabel => sky.kind.label;

  /// 游戏内累计时间（诊断用：判断帧循环到底跑了多少）。
  double get elapsedTime => _time;

  // ---- 第三人称相机（距离 / 偏航 / 俯仰）----
  double camYaw = 0.0;

  /// 俯仰角偏小：让相机接近平视，天空与远山能进画面（俯角太大就只能看到地面）。
  double camPitch = 0.30;
  double camDistance = 8.5;
  final vm.Vector3 _camTarget = vm.Vector3.zero();
  bool _camTargetInitialized = false;

  /// 复用的"头顶朝上"常量。音频听者的 up 与相机 up 是同一个；
  /// 写成字段而不是每帧 `vm.Vector3(0,1,0)`，避免每帧一次堆分配。
  static final vm.Vector3 _upAxis = vm.Vector3(0, 1, 0);

  // ------------------------------------------------------------------
  // 组装
  // ------------------------------------------------------------------

  /// 启动各阶段的耗时（毫秒），由 [initialize] 逐段测量。
  ///
  /// 存在的理由：
  ///   * **启动阻塞只能被测量、不能被猜**。`initialize()` 里每一段都是主 isolate 上的
  ///     同步程序化生成，而它们在"点开游戏到能操作"这条时间线上的占比完全不可见 ——
  ///     实测 `sky`+`flora`+`grass` 三段就吃掉十几秒，而音频合成只有 ~0.2s。
  ///     没有这张表，很容易把"键盘几十秒没反应"错记到音频账上。
  ///   * 它是**回归护栏**：任何一段突然变慢（新增一层植被、多一层云）都会在
  ///     `state.bootMs` 里直接看到，而不是等到有人抱怨"进游戏卡"。
  final Map<String, int> bootMs = {};

  /// 启动各阶段的时间线（谁在什么时刻开始/结束），用于定位"哪一段后面开始能操作"。
  final List<Map<String, Object?>> bootTimeline = [];

  /// 必须在渲染前等 `initializeStaticResources` 完成——引擎在就绪之前会跳过每一帧。
  ///
  /// 每一段之间刻意 `await` 让出事件循环：否则整段程序化生成会是一个不可打断的
  /// 同步块，期间**键盘事件根本排不进来**（`KeyboardListener` 收不到回调），
  /// 表现就是"进了游戏几十秒按键没反应"。让出之后按键能在生成过程中被记录下来，
  /// 一到 `_ready` 就立刻生效。
  Future<void> initialize() async {
    await _bootStep('staticResources', () => Scene.initializeStaticResources());

    await _bootStep('sky', () {
      sky.build(scene);
      _applyLook();
    });

    await _bootStep('terrainWater', () {
      scene.add(terrain.buildNode());
      scene.add(water.buildNode());
    });

    // 水下那三层：河床水草 → 鱼虾。都挂在水面之下，靠水面的半透明被看见。
    await _bootStep('aquaticFlora', () {
      for (final node in aquatic.buildNodes()) {
        scene.add(node);
      }
    });
    await _bootStep('aquaticFauna', () {
      for (final node in fauna.buildNodes()) {
        scene.add(node);
      }
    });

    await _bootStep('grass', () {
      scene.add(Node(name: 'grass')
        ..addComponent(InstancedMeshComponent(grass.build())));
    });

    // 植被层与石块：几何与分布全是程序化生成的；顺序在 FloraSystem 内部
    // 保证（灌木先放置，灌木落点作为乔木的避让点）。
    await _bootStep('flora', () {
      for (final node in flora.buildNodes()) {
        scene.add(node);
      }
    });

    await _bootStep('player', () {
      _buildPlayer();
      // 先算一次实例矩阵：距离补偿依赖角色位置，等第一帧 tick 会让首帧
      // 出现"没有加宽/矮化"的突兀画面。
      grass.applyWind(0, focus: player.position, cameraPos: _cameraPosition());
      _spawnPickups();
    });

    // 音频**不在这里烘焙**：`beginBaking()` 只把任务排进后台队列就返回。
    //
    // 程序化合成的 CPU 成本是实在的（整套环境音约 0.6–1.0s），而它一旦落在
    // `initialize()` 里，就变成了"听得到声音之前，玩家必须等它算完"。
    // 现在它在**独立 isolate**（原生）或**分片让出**（Web）里跑，
    // 启动与按键响应都不受它影响。
    await _bootStep('audioBake', () {
      audio.beginBaking();
    });

    _ready = true;
    bootTimeline.add({'phase': 'ready', 'ms': _bootClock.elapsedMilliseconds});
  }

  final Stopwatch _bootClock = Stopwatch();

  /// 跑一个启动阶段并记录耗时，然后让出一次事件循环。
  ///
  /// 让出（`await Future<void>.delayed(Duration.zero)`）是**关键**：
  /// 它把控制权交回事件循环，挂起的键盘事件得以派发、加载画面得以重绘。
  Future<void> _bootStep(String name, FutureOr<void> Function() body) async {
    if (!_bootClock.isRunning) _bootClock.start();
    final t0 = _bootClock.elapsedMilliseconds;
    await body();
    final t1 = _bootClock.elapsedMilliseconds;
    bootMs[name] = (bootMs[name] ?? 0) + (t1 - t0);
    bootTimeline.add({'phase': name, 'ms': t1});
    // 让出事件循环：不这么做，下面每一段之间都排不进任何输入事件。
    await Future<void>.delayed(Duration.zero);
  }

  void _buildPlayer() {
    player = buildKirbyNode();
    scene.add(player);

    // 地形是解析高度场，控制器直接采样高度，不需要射线/碰撞体。
    // （内置 ThirdPersonControllerComponent 依赖射线 + 组件挂载时序，
    //   在 Web 上实测无法驱动移动，详见 player_controller.dart 的说明。）
    controller = PlayerController(node: player, terrain: terrain);
    controller.placeAt(0, 0);
  }

  /// 阶段一的关卡内容：三圈共 12 颗星核，绕中心均匀铺开，
  /// 让玩家必须绕着场地跑一圈才能收集完。
  void _spawnPickups() {
    const rings = <({double radius, int count})>[
      (radius: 8.0, count: 4),
      (radius: 14.0, count: 4),
      (radius: 19.5, count: 4),
    ];

    var index = 0;
    for (final ring in rings) {
      for (var i = 0; i < ring.count; i++) {
        final angle = (i / ring.count) * math.pi * 2 + index * 0.35;
        final x = math.cos(angle) * ring.radius;
        final z = math.sin(angle) * ring.radius;
        final baseY = terrain.heightAt(x, z) + 1.15;

        final node = buildPickupNode(index: index);
        node.position = vm.Vector3(x, baseY, z);
        scene.add(node);
        pickups.add(Pickup(node, baseY, index * 1.3));
        index++;
      }
    }
  }

  // ------------------------------------------------------------------
  // 每帧
  // ------------------------------------------------------------------

  void tick(Duration elapsed, double dt) {
    if (!_ready) return;
    _time += dt;
    _frame++;

    // 0) 自动演示：注入虚拟输入（与真实键盘走同一条路径）
    if (demoDriving) _driveDemo();

    // 1) 角色：输入 → 移动 / 跳跃 / 朝向
    _updatePlayer(dt);

    // 2) 各系统自治更新
    _updateSky(dt);
    _updatePickups();

    // 水面动效：顶点只有约 1.3k 个，每 3 帧更新一次（约 13Hz）就够顺滑，
    // 省下的帧预算给新增的植被层（实测加植被后帧率从 42 掉到 35.6）。
    if (_frame % 3 == 0) water.tick(_time);

    // 水草摇曳：与水面同源的行波（相位都来自 flow.flowPhase），
    // 所以"波纹走过去"和"草弯腰的波走过去"是同一个波。
    if (_frame % 4 == 0) aquatic.tick(_time);

    // 鱼虾：位置每帧积分（游动的轨迹才连续），实例矩阵每 2 帧写一次
    // —— 引擎在实例矩阵变动时会重打包整块实例缓冲，120 个实例虽小，
    // 也没必要每帧写两遍。
    fauna.advance(dt, player.position);
    if (_frame % 2 == 0) fauna.applyTransforms(_time);

    // 跃出水面的鱼落回水时，在水面留一圈涟漪、并响一声水花
    //（同一条水、同一个流场：画面与声音读的是同一份额）。
    for (var i = 0; i < fauna.splashCount; i++) {
      final splash = fauna.splashes[i];
      // 涟漪：**每一个事件都要**（视觉上多一圈涟漪没有代价，反而是"水面活着"）。
      water.addRipple(splash.x, splash.z, splash.strength);
      // 声音：3D 声源 + 世界坐标。**闸门在音频层内部**（最小间隔 / 距离上限），
      // 所以这里不需要为"鱼跃得太勤"打补丁 —— 上一版正是缺了那道闸门，
      // 平均每秒约 3 声水花被玩家听成了雨声。
      audio.splash(size: splash.size, x: splash.x, z: splash.z);
    }

    // 音频：听者 = 角色锚点（位置）+ 相机（朝向）。
    // 河流层的声源 = 河道上离角色最近的点，内部 10Hz 节流；
    // 听者朝向每帧跟（转身时声像不能滞后）。
    audio.update(
      dt,
      listener: AudioListener(
        // 位置取**角色锚点**而不是相机：相机在身后 8–22m，拿它当听者会把
        // "离河多远"算虚。`_camTarget` 就是平滑过的角色锚点，直接用。
        position: _camTarget,
        // 朝向取相机：转身时左右声像才会跟着转。
        forward: (_camTarget - _cameraPosition()).normalized(),
        up: _upAxis,
        velocity: vm.Vector3.zero(), // AudioManager 自己按帧差算速度
      ),
      characterPos: player.position,
      // 是否落地：脚步只在落地时响。
      grounded: !controller.isAirborne,
      // 天气快照：**过渡期间取插值中的值**，所以雨声是连着雨势渐入的，
      // 而不是在过渡结束那一帧突然切进来。
      weather: WeatherAudio(
        rainAmount: sky.current.rainAmount,
        windAmount: sky.windStrength,
        nightAmount: sky.current.nightAmount,
      ),
    );

    // 风摆是 O(实例数) 的 CPU 活。引擎在实例矩阵变化时会重打包整个实例缓冲，
    // 所以这里刻意压低频率（约 12Hz）：草摆是 1.6 rad/s 的慢波，12Hz 采样完全够，
    // 省下的 CPU 换成更多草叶。macOS/Metal 实测：8 万根 @ 每 3 帧 → 38.6 FPS。
    if (_frame % 5 == 0) {
      grass.applyWind(
        _time,
        focus: player.position,
        cameraPos: _cameraPosition(),
        strength: sky.windStrength,
      );
    }

    _updateCamera(dt);

    // 边沿触发的按键只活一帧。
    input.endFrame();

    // 3) 刷新给宿主（MCP）看的状态快照。
    //
    //    **限频推送，不再每帧构建。**
    //
    //    上一版是每帧 `GameBridge.publish(bridgeStateJson())`：而在 macOS 上
    //    `GameBridge` 本身就是空实现（见 `mcp/bridge.dart`）—— 也就说每帧花
    //    力气构建一整张诊断表（含 `jsonEncode`）**推给一个不存在的订阅者**，
    //    而 MCP 宿主本来就会在问的时候直接调 `bridgeStateJson()` 拿实时值。
    //
    //    代价不只是白干活：诊断表里有几个字段要经 FFI 抢 SoLoud 的全局音频锁，
    //    而那个锁被 CoreAudio 回调里的混音器持有整段 `mix()`。每帧抢锁会把
    //    主线程（渲染 + 输入）整段挡住，甚至被饿死很久 —— 玩家看到的就是
    //    "进了游戏按键没反应，几十秒后才恢复"。
    //
    //    所以：按 4Hz 推送（Web 通道足够新），需要即时值的宿主走 `state` 命令。
    if (_time - _statePublishedAt >= _statePublishInterval) {
      _statePublishedAt = _time;
      GameBridge.publish(bridgeStateJson());
    }
  }

  /// 状态快照的推送间隔。0.25s ≈ 4Hz：对"页面拉取状态"这种用途绰绰有余，
  /// 同时把每帧的构建 + 抢锁开销降到原来的 1/8。
  static const double _statePublishInterval = 0.25;

  /// 演示输入：持续前进，并在"左前 / 右前"之间每 4 秒切换，走出 Z 字覆盖场地；
  /// 每 1.9 秒跳一次。目的是让无头环境也能跑通"移动 → 跳跃 → 吃到星核"整条链路。
  void _driveDemo() {
    input.setVirtual(LogicalKeyboardKey.keyW, true);
    final turnLeft = (_time / 4.0).floor() % 2 == 0;
    input.setVirtual(LogicalKeyboardKey.keyA, turnLeft);
    input.setVirtual(LogicalKeyboardKey.keyD, !turnLeft);

    final cycle = (_time / 1.9).floor();
    if (cycle != _demoJumpCycle) {
      _demoJumpCycle = cycle;
      input.queueJump();
    }
  }

  void _updatePlayer(double dt) {
    final wasAirborne = controller.isAirborne;
    // 下落速度自己按帧差算：控制器的公开面里没有竖直速度，而落地音的"轻重"
    // 恰恰由它决定（从高处摔下来与轻轻点地不该是同一声）。
    final prevY = _prevPlayerY;
    final hadPrevY = _hasPrevPlayerY;

    final wantJump = input.consumeJump();
    controller.update(
      dt,
      moveAxis: input.moveAxis,
      running: input.isRun,
      // 相对相机朝向移动（第三人称标准手感）。
      // 若发现角色朝反方向跑，把 camYaw 改成 camYaw + math.pi。
      cameraYaw: camYaw,
      jump: wantJump,
    );

    _hasPrevPlayerY = true;
    _prevPlayerY = player.position.y;

    // 起跳音：只在"这一帧真的离地"时响，按住空格也不会连发。
    if (!wasAirborne && controller.isAirborne) audio.jump();

    // 落地音：力度来自真的下落速度，所以从高处摔下来与轻轻点地听得出区别。
    if (wasAirborne && !controller.isAirborne) {
      final vy = (hadPrevY && dt > 1e-4)
          ? (player.position.y - prevY) / dt
          : 0.0;
      audio.land(impact: (vy.abs() / 9.0).clamp(0.0, 1.0));
    }
  }

  double _prevPlayerY = 0;
  bool _hasPrevPlayerY = false;

  void _updateSky(double dt) {
    // 把角色位置交给天空系统，雨幕才能跟着角色走。
    // 另外把相机位置也交进去：雨丝的屏幕宽度取决于到**相机**的距离，
    // 只有角色位置的话，落在相机与角色之间的雨滴会被当成远景而渲染成巨柱。
    sky.tick(dt, _time, focus: player.position, cameraPos: _cameraPosition());
    // 天气过渡期间同步刷新外观（雾/曝光跟着插值走）。
    if (sky.isTransitioning || _frame == 1) _applyLook();
  }

  /// 相机位置。与 [buildCamera] 用同一套公式，保证两者一致。
  ///
  /// 这里多一道**贴地保护**：加入河谷地形之后，角色走到河边或下到谷底时，
  /// 相机（在身后 8–22m）很容易落进河岸内部，画面会变成"从地底往上看"
  /// （实测：会出现大片灰色洞与悬空的石头）。抬到地面之上 0.6m 即可，
  /// 幅度很小、正常地形上完全看不出来。
  vm.Vector3 _cameraPosition() {
    final dir = vm.Vector3(
      math.cos(camPitch) * math.sin(camYaw),
      math.sin(camPitch),
      math.cos(camPitch) * math.cos(camYaw),
    );
    final pos = _camTarget + dir * camDistance;
    final groundY = terrain.heightAt(pos.x, pos.z) + 0.6;
    if (pos.y < groundY) pos.y = groundY;
    return pos;
  }

  void _updatePickups() {
    final playerPos = player.position;

    for (final pick in pickups) {
      if (pick.collected) continue;

      animatePickup(pick.node, _time, pick.baseHeight, phase: pick.phase);

      final dx = pick.node.position.x - playerPos.x;
      final dy = pick.node.position.y - playerPos.y;
      final dz = pick.node.position.z - playerPos.z;
      if (dx * dx + dy * dy + dz * dz < 1.5 * 1.5) {
        pick.collected = true;
        pick.node.scale = vm.Vector3.zero(); // 零缩放即"拿走"
        score++;
        audio.pickup();
        // 收齐了来一小段上行琶音：这是玩法事件音走同一条通道的例子。
        if (pickups.isNotEmpty && score >= pickups.length) audio.levelClear();
      }
    }
  }

  void _updateCamera(double dt) {
    final desired = player.position + vm.Vector3(0, 1.15, 0);
    if (!_camTargetInitialized) {
      _camTarget.setFrom(desired);
      _camTargetInitialized = true;
    } else {
      // 指数平滑：与帧率无关，避免高帧率下抖得更快。
      // Vector3 是可变对象，这里原地累加，避免每帧分配新向量。
      final k = 1.0 - math.exp(-9.0 * dt);
      _camTarget.add((desired - _camTarget) * k);
    }
  }

  /// 由 `SceneView` 每帧调用。
  ///
  /// `fovRadiansY` 显式提到 **60°**（引擎默认 45°）。默认值下画面里的天空
  /// 只有地平线上方 5.3°（俯角 17.2° − 半视场 22.5°），月亮（仰角 12°）
  /// 与银河主体全部在画外——夜景做了也看不见。60° 把上缘推到 12.8°，
  /// 夜空才真正进入视野（代价：地面物体略微变小、边缘有广角透视感）。
  PerspectiveCamera buildCamera() {
    return PerspectiveCamera(
      position: _cameraPosition(),
      target: _camTarget,
      up: vm.Vector3(0, 1, 0),
      fovRadiansY: 60 * math.pi / 180,
      fovNear: 0.1,
      fovFar: 1500,
    );
  }

  // ------------------------------------------------------------------
  // 外部操作（UI / 后续 MCP 都走这里）
  // ------------------------------------------------------------------

  void orbitCamera(double dxPixels, double dyPixels) {
    camYaw -= dxPixels * 0.005;
    camPitch = (camPitch + dyPixels * 0.004).clamp(-0.15, 1.25);
  }

  void zoomCamera(double scrollDelta) {
    camDistance = (camDistance + scrollDelta * 0.02).clamp(4.0, 22.0);
  }

  /// 切到下一种天气，返回新天气。
  WeatherKind cycleWeather() {
    audio.uiTap();
    return sky.cycle();
  }

  /// 用户第一次输入时调用（按键或指针按下）。
  ///
  /// 存在的唯一理由是**解锁 Web 音频**：浏览器的 autoplay policy 要求音频
  /// 由用户手势触发，否则 `play()` 会被静默拒绝（桌面端没有这条限制）。
  /// 两端走同一条路径 —— "Web 没声音、桌面有声音"这类差异在换通道调试时
  /// 会白烧掉一整轮排查。
  void notifyUserGesture() => unawaited(audio.arm());

  /// 直接指定天气。
  void setWeather(WeatherKind kind) {
    audio.uiTap();
    sky.applyWeather(kind);
  }

  /// 重开本关：清空收集进度、把角色放回中心。
  void restart() {
    audio.uiTap();
    _hasPrevPlayerY = false;
    for (final pick in pickups) {
      pick.collected = false;
      pick.node.scale = vm.Vector3(1, 1, 1);
      pick.node.position =
          vm.Vector3(pick.node.position.x, pick.baseHeight, pick.node.position.z);
    }
    score = 0;
    controller.placeAt(0, 0);
    audio.resetMotion();
    _camTargetInitialized = false;
  }

  void _applyLook() {
    final w = sky.current;
    // 写成 `baseEnvironment` 而不是 `environmentSettings`：
    // 河谷雾体积（`scene.environmentVolumes`）由引擎按相机位置混合到
    // `baseEnvironment` 之上，而 base 为 null 时那整段混合会被直接跳过
    // —— 此时体积形同不存在（这也是之前"谷雾完全不生效"的真正原因）。
    scene.baseEnvironment = buildKirbyLook(
      fogDensity: w.fogDensity,
      exposure: w.exposure,
      environmentIntensity: w.environmentIntensity,
      // 雾色跟随天弯染色，雨天更灰、晴天更亮；夜色下的压暗在 sky 侧统一做
      // （见 `SkySystem.fogColor`）—— 两处各算一遍的话，河谷雾体积
      // 与全局雾会不一致，进出河谷时雾色会突跳。
      fogColor: sky.fogColor,
      // 空气透视：远处地形褪进天光而不是撞上一堵灰墙。
      fogSkyColorInfluence: sky.fogSkyColorInfluence,
      // 天空盒必须随之外观一起带上：不在时 skybox 会被清成 null，天空变纯黑。
      skybox: sky.skybox,
    );
  }

  // ------------------------------------------------------------------
  // 桥接（宿主 / MCP）
  // ------------------------------------------------------------------

  /// 允许远程注入的按键白名单。
  ///
  /// 只放行玩法需要的键，而不是把任意 `LogicalKeyboardKey` 都暴露出去：
  /// 键名对不上时能立刻报错，而不是静默无效——"名字拼错但没人报错"
  /// 是自动化脚本最经典的坑。
  static const Map<String, LogicalKeyboardKey> _bridgeKeys = {
    'KeyW': LogicalKeyboardKey.keyW,
    'KeyA': LogicalKeyboardKey.keyA,
    'KeyS': LogicalKeyboardKey.keyS,
    'KeyD': LogicalKeyboardKey.keyD,
    'ArrowUp': LogicalKeyboardKey.arrowUp,
    'ArrowDown': LogicalKeyboardKey.arrowDown,
    'ArrowLeft': LogicalKeyboardKey.arrowLeft,
    'ArrowRight': LogicalKeyboardKey.arrowRight,
    'ShiftLeft': LogicalKeyboardKey.shiftLeft,
    'Space': LogicalKeyboardKey.space,
  };

  /// 支持的命令清单。`capabilities` 命令会返回它，宿主可据此自检。
  static const List<String> bridgeCommands = [
    'capabilities',
    'set_weather',
    'cycle_weather',
    'restart',
    'set_camera',
    'teleport',
    'hold_keys',
    'release_keys',
    'jump',
    'set_demo',
    'orbit_camera',
    'zoom_camera',
    'arm_audio',
    'reset_audio',
    'set_layer',
    'set_bus_gain',
    'audio_levels',
  ];

  @override
  String bridgeStateJson() {
    // player / controller 是 late final，未就绪时取值会抛，必须先挡一道。
    if (!_ready) return jsonEncode({'ready': false});

    final p = player.position;
    return jsonEncode({
      'ready': true,
      'score': score,
      'pickupsTotal': pickups.length,
      'cleared': cleared,
      'position': [p.x, p.y, p.z],
      'groundY': terrain.heightAt(p.x, p.z),
      'airborne': controller.isAirborne,
      'facing': controller.facing,
      'weather': sky.kind.name,
      'weatherLabel': sky.kind.label,
      'elapsed': _time,
      'frame': _frame,
      'demo': demoDriving,
      'grassBlades': grass.instanceCount,
      'flora': flora.counts,
      'aquatic': aquatic.counts,
      'fauna': fauna.counts,
      // 音效状态：宿主可据此确认"没声音"卡在哪一环（合成？起播？），
      // 以及**声源/听者的实时位姿**（空间音频到底有没有在跟角色走）。
      // 这些字段的构造在 `RiverAudio.diagnostics()` 里，和引擎细节放在一起。
      'audio': audio.diagnostics(),
      // 启动各阶段耗时（毫秒）与时间线：用来回答"进游戏到能操作之间，时间花在哪"。
      'bootMs': bootMs,
      'bootTimeline': bootTimeline,
      'camera': _cameraJson(),
    });
  }

  @override
  String bridgeCommand(String commandJson) {
    final Map<String, dynamic> req;
    try {
      final decoded = jsonDecode(commandJson);
      if (decoded is! Map<String, dynamic>) {
        return _bridgeError('command must be a JSON object');
      }
      req = decoded;
    } on FormatException catch (e) {
      return _bridgeError('invalid JSON: ${e.message}');
    }

    final cmd = req['cmd'];
    if (cmd is! String) return _bridgeError('missing "cmd"');

    // 先判命令名是否已知：命令名拼错属于**协议层**错误，
    // 不该被"世界还没就绪"掩盖——否则排查时会误以为是时序问题而绕远路。
    if (!bridgeCommands.contains(cmd)) {
      return jsonEncode({
        'ok': false,
        'error': 'unknown command "$cmd"',
        'allowed': bridgeCommands,
      });
    }

    // 只有 capabilities 允许在世界就绪前调用——它没有副作用，
    // 且正好用来让宿主判断"桥接装上了但场景还没好"。
    final ready = _ready;
    if (!ready && cmd != 'capabilities') {
      return _bridgeError('world not ready yet');
    }

    return switch (cmd) {
      'capabilities' => jsonEncode({
          'ok': true,
          'ready': ready,
          'commands': bridgeCommands,
          'keys': _bridgeKeys.keys.toList(),
          'weathers': WeatherKind.values.map((k) => k.name).toList(),
        }),
      'set_weather' => _cmdSetWeather(req),
      'cycle_weather' => jsonEncode({'ok': true, 'weather': cycleWeather().name}),
      'restart' => _cmdRestart(),
      'set_camera' => _cmdSetCamera(req),
      'teleport' => _cmdTeleport(req),
      'hold_keys' => _cmdKeys(req, down: true),
      'release_keys' => _cmdKeys(req, down: false),
      'jump' => _cmdJump(),
      'set_demo' => _cmdSetDemo(req),
      'arm_audio' => _cmdArmAudio(),
      'reset_audio' => _cmdResetAudio(),
      'set_layer' => _cmdLayer(req),
      'set_bus_gain' => _cmdBusGain(req),
      'audio_levels' => _cmdAudioLevels(),
      'orbit_camera' => _cmdOrbit(req),
      'zoom_camera' => _cmdZoom(req),
      _ => jsonEncode({
          'ok': false,
          'error': 'unknown command "$cmd"',
          'allowed': bridgeCommands,
        }),
    };
  }

  String _cmdSetWeather(Map<String, dynamic> req) {
    final kind = _weatherByName(req['kind']);
    if (kind == null) {
      return jsonEncode({
        'ok': false,
        'error': 'unknown weather "${req['kind']}"',
        'allowed': WeatherKind.values.map((k) => k.name).toList(),
      });
    }
    setWeather(kind);
    return jsonEncode({'ok': true, 'weather': kind.name});
  }

  String _cmdRestart() {
    restart();
    return jsonEncode({'ok': true, 'score': score});
  }

  String _cmdSetCamera(Map<String, dynamic> req) {
    if (req['yaw'] is num) camYaw = (req['yaw'] as num).toDouble();
    if (req['pitch'] is num) {
      camPitch = (req['pitch'] as num).toDouble().clamp(-0.15, 1.25);
    }
    if (req['distance'] is num) {
      camDistance = (req['distance'] as num).toDouble().clamp(4.0, 22.0);
    }
    return jsonEncode({'ok': true, 'camera': _cameraJson()});
  }

  String _cmdTeleport(Map<String, dynamic> req) {
    final x = req['x'];
    final z = req['z'];
    if (x is! num || z is! num) {
      return _bridgeError('teleport needs numeric "x" and "z"');
    }
    controller.placeAt(x.toDouble(), z.toDouble());
    audio.resetMotion();
    // 让相机立刻跟过去，而不是从旧位置平滑飞过来——
    // 否则紧接着的截图会拍到"半路上"的画面。
    _camTargetInitialized = false;
    return jsonEncode({'ok': true, 'position': _playerJson()});
  }

  String _cmdKeys(Map<String, dynamic> req, {required bool down}) {
    // release_keys 支持 {"all": true} 一次性松开全部虚拟键。
    if (!down && req['all'] == true) {
      input.clearVirtual();
      return jsonEncode({'ok': true, 'released': 'all'});
    }

    final keys = req['keys'];
    if (keys is! List) return _bridgeError('"keys" must be an array');

    final unknown = <String>[];
    for (final name in keys) {
      final key = _bridgeKeys[name];
      if (key == null) {
        unknown.add('$name');
        continue;
      }
      input.setVirtual(key, down);
    }
    if (unknown.isNotEmpty) {
      return jsonEncode({
        'ok': false,
        'error': 'unknown key names',
        'unknown': unknown,
        'allowed': _bridgeKeys.keys.toList(),
      });
    }
    return jsonEncode({'ok': true});
  }

  String _cmdJump() {
    input.queueJump();
    return jsonEncode({'ok': true});
  }

  String _cmdSetDemo(Map<String, dynamic> req) {
    demoDriving = req['on'] == true;
    if (!demoDriving) {
      // 关掉演示时顺手松开它注入的方向键，
      // 否则角色会带着上一次的虚拟输入一直往前跑。
      input
        ..setVirtual(LogicalKeyboardKey.keyW, false)
        ..setVirtual(LogicalKeyboardKey.keyA, false)
        ..setVirtual(LogicalKeyboardKey.keyD, false);
    }
    return jsonEncode({'ok': true, 'demo': demoDriving});
  }  /// 远程解锁音频（等价于"用户按了键/点了画面"）。
  ///
  /// 存在的理由是**验证**：浏览器要求音频由用户手势解锁，而 MCP 注入的虚拟
  /// 输入不算用户手势 —— 没有这条命令，自动化就永远验不到"起播到底通没通"
  /// （state 里的 `audio.started` 也会一直停在 false，看起来像功能没做）。
  ///
  /// **不再"强制拆引擎重建"**：那条路会先 `deinit` 再 `init`，实测在真实设备上
  /// 要停顿主线程约 1.2 秒 —— 而这正是玩家"第一次按键没反应"的成因。
  /// 需要强制重置时用 `reset_audio`（它是调试命令，它自己带着这个代价）。
  String _cmdArmAudio() {
    unawaited(audio.preArm());
    return jsonEncode({
      'ok': true,
      'started': audio.isPlaying,
      'engine': audio.isEngineReady,
      'baked': audio.bakedAssets,
    });
  }

  /// 刷新并返回**引擎侧实测**的电平与声部数。
  ///
  /// 单独一条命令而不是塞进 `state` 里，是因为它要经 FFI 抢 SoLoud 的全局
  /// 音频锁（见 `_publishState`）—— 只能"按需拉"，不能"每帧看"。
  /// 这也是验收工具 `tool/audio_audit.mjs` 里"真的在出声"那条判据的来源。
  String _cmdAudioLevels() {
    audio.refreshProbe();
    return jsonEncode({
      'ok': true,
      'outputLeft': audio.probeLeft,
      'outputRight': audio.probeRight,
      'activeVoices': audio.probeVoices,
      'engineTimeMs': audio.probeEngineMs,
    });
  }

  /// 强制重置音频引擎（热重启 / 排查原生侧残留声部时用）。
  ///
  /// 与 `arm_audio` 分开是因为它的代价是**可感知的停顿**：它必须把原生侧的
  /// 引擎整个拆掉再重建。把它藏在一条日常命令里，等于给每次自动化都加一秒卡顿。
  String _cmdResetAudio() {
    unawaited(audio.reset().then((_) => audio.preArm()));
    return jsonEncode({'ok': true});
  }

  /// 单独控制某一层环境音（需求里的"各自可单独控制音量/启停"的远程入口）。
  String _cmdLayer(Map<String, dynamic> req) {
    final name = req['layer'];
    AmbienceLayer? layer;
    for (final l in AmbienceLayer.values) {
      if (l.name == name) layer = l;
    }
    if (layer == null) {
      return jsonEncode({
        'ok': false,
        'error': 'unknown layer "$name"',
        'allowed': AmbienceLayer.values.map((l) => l.name).toList(),
      });
    }
    if (req['mute'] is bool) audio.setLayerMuted(layer, req['mute'] as bool);
    if (req['trim'] is num) audio.setLayerTrim(layer, (req['trim'] as num).toDouble());
    return jsonEncode({
      'ok': true,
      'layer': layer.name,
      'target': audio.diagnostics()['targets'],
    });
  }

  /// 设置总线音量（环境音 / 音效 / 界面）。
  String _cmdBusGain(Map<String, dynamic> req) {
    final name = req['bus'];
    AudioBus? bus;
    for (final b in AudioBus.values) {
      if (b.name == name) bus = b;
    }
    if (bus == null) {
      return jsonEncode({
        'ok': false,
        'error': 'unknown bus "$name"',
        'allowed': AudioBus.values.map((b) => b.name).toList(),
      });
    }
    if (req['gain'] is num) audio.setBusGain(bus, (req['gain'] as num).toDouble());
    return jsonEncode({'ok': true, 'bus': bus.name});
  }

  String _cmdOrbit(Map<String, dynamic> req) {
    orbitCamera(
      (req['dx'] as num?)?.toDouble() ?? 0,
      (req['dy'] as num?)?.toDouble() ?? 0,
    );
    return jsonEncode({'ok': true, 'camera': _cameraJson()});
  }

  String _cmdZoom(Map<String, dynamic> req) {
    zoomCamera((req['delta'] as num?)?.toDouble() ?? 0);
    return jsonEncode({'ok': true, 'camera': _cameraJson()});
  }

  String _bridgeError(String message) =>
      jsonEncode({'ok': false, 'error': message});

  Map<String, double> _cameraJson() => {
        'yaw': camYaw,
        'pitch': camPitch,
        'distance': camDistance,
      };

  List<double> _playerJson() {
    final p = player.position;
    return [p.x, p.y, p.z];
  }

  static WeatherKind? _weatherByName(Object? name) {
    for (final kind in WeatherKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}
