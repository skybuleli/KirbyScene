/// 河流的水面：把纯数学的波场模型 [WaterWaves] 接到 flutter_scene 上。
///
/// ## 为什么这一层这么薄
///
/// 水面动效的全部数学都在 `water_waves.dart` 里 —— 那里不 import
/// flutter_scene，因此能在没有 GPU 上下文的环境里单测。本文件只做三件事：
///
///   1. 把 [WaterWaves] 的顶点/颜色/法线三个 Float32List 送进 [MeshGeometry]；
///   2. 组装材质与节点；
///   3. 把外部的涟漪事件转发给模型。
///
/// ## 动效为什么走 CPU 顶点，以及为什么必须更新法线
///
/// flutter_scene 目前没有暴露自定义着色器，水面动效只能改顶点属性。引擎支持
/// `GeometryStorage.updatable` + `updatePositions/updateColors/updateNormals`。
/// 本水面有 2400 个顶点（240 行 × 10 列），每 3 帧改一遍完全无压力
/// （对比：草叶有 11 万个实例，才需要精打细算）。
///
/// **`updateNormals` 是这里最关键的一行**：水面是高度场，只动顶点位置的话
/// 法线一直朝上，光照下几乎看不出在动（只有轮廓在抖）。把逐帧重算的单位法线
/// 上传之后，波纹才会随光照闪动，肉眼立刻可辨。计算见
/// [WaterWaves.update]（对位移后的网格做有限差分）。
library;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'flow.dart';
import 'terrain.dart';
import 'water_waves.dart';

class WaterSurface {
  WaterSurface({
    required this.terrain,
    RiverFlow? flow,
    int rows = 240,
    int cols = 10,
    int seed = 4242,
  }) : flow = flow ?? RiverFlow(terrain) {
    // 流场是**可共享**的唯一水动力源：world.dart 若把它交给水草/鱼虾/音效，
    // 传进来即可，水面不会另立一套流速。
    waves = WaterWaves(flow: this.flow, rows: rows, cols: cols, seed: seed);
  }

  final Terrain terrain;
  final RiverFlow flow;

  /// 纯数学波场模型（持有网格参数与三个顶点缓冲）。
  late final WaterWaves waves;

  MeshGeometry? _geometry;

  int get vertexCount => waves.vertexCount;

  /// 按波场的岸线参数生成带状网格，并把它建成 `updatable` 几何体。
  MeshGeometry buildGeometry() {
    final builder = GeometryBuilder(deduplicate: false);

    final positions = waves.positions;
    final colors = waves.colors;
    for (var vi = 0; vi < waves.vertexCount; vi++) {
      final o = vi * 3;
      final c = vi * 4;
      builder
        // 颜色在这里只是初始值，之后每帧由 updateColors 覆盖。
        ..color(vm.Vector4(colors[c], colors[c + 1], colors[c + 2], colors[c + 3]))
        ..addVertex(vm.Vector3(positions[o], positions[o + 1], positions[o + 2]));
    }

    // 拓扑与单测共用同一份索引，避免"测试数的三角形"和"渲染的"不一致。
    final indices = waves.indices;
    for (var t = 0; t < indices.length; t += 3) {
      builder.addTriangle(indices[t], indices[t + 1], indices[t + 2]);
    }

    final geometry = builder.build(storage: GeometryStorage.updatable);
    // build 会自己生成一版法线（由平面网格差分而来）；这里立刻换成波场
    // 算好的、已经带位移的法线。
    geometry.updateNormals(waves.normals);
    geometry.updateColors(waves.colors);
    _geometry = geometry;
    return geometry;
  }

  /// 每 3 帧（约 13Hz）由 world.dart 调用一次，推进波场并上传三个属性。
  void tick(double time) {
    final geometry = _geometry;
    if (geometry == null) return;
    waves.update(time);
    geometry.updatePositions(waves.positions);
    geometry.updateColors(waves.colors);
    geometry.updateNormals(waves.normals);
  }

  /// 在 (x, z) 触发一个点源涟漪（鱼的跃出、雨滴落水都调它）。
  void addRipple(double x, double z, double strength) =>
      waves.addRipple(x, z, strength);

  /// 组装成可直接 add 到场景的节点。
  Node buildNode() {
    final material = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(1, 1, 1, 1) // 颜色交给顶点色
      // **必须显式设为 blend**：默认 opaque 会完全忽略 alpha 通道，
      // 水面就会变成一块不透明的塑料布 —— 水下那整层生态（水草、鱼、虾）
      // 连同河床一起被挡住（`sky.dart` 的雨幕踩过同一个坑）。
      ..alphaMode = AlphaMode.blend
      // 粗糙度不能太低：0.18 时整个水面会把天空镜面反射成一片白，层次全没了
      //（实测）。但也**不能太高** —— 0.46 时水面几乎只剩漫反射，低角度看过去
      // 就是一块"浅绿色地面"（实机验证：截图上被读成草地）。0.30 保留一条
      // 随视角掠过的高光带，那是"这是水"最直接的视觉线索。
      ..roughnessFactor = 0.30
      ..metallicFactor = 0.0
      ..doubleSided = true; // 从岸边低角度看过去也要能看到
    return Node(name: 'water', mesh: Mesh(buildGeometry(), material));
  }
}
