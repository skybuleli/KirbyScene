// 临时原生复现：使用项目依赖中的 SoLoud 源码与空设备后端，手动推进混音。
#include "soloud.h"
#include "soloud_wav.h"
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <vector>
int main(int argc, char** argv) {
  const float velocity = argc > 1 ? std::atof(argv[1]) : 0;
  SoLoud::Soloud engine;
  if (engine.init(SoLoud::Soloud::CLIP_ROUNDOFF, SoLoud::Soloud::NULLDRIVER, 44100, 2048, 2)) return 2;
  std::vector<float> pcm(44100);
  for (size_t i=0; i<pcm.size(); ++i) pcm[i]=0.1f*std::sin(i*0.03f);
  SoLoud::Wav wave;
  wave.loadRawWave(pcm.data(), pcm.size(), 44100, 1, true, false);
  wave.setLooping(true);
  engine.set3dListenerParameters(70,0,0,70,0,-1,0,1,0,velocity,0,0);
  auto handle=engine.play3d(wave,30,0,0,0,0,0,0.5f);
  engine.set3dSourceDopplerFactor(handle,0.15f);
  engine.update3dAudio();
  std::cout << "velocity=" << velocity << " samplerate=" << engine.getSamplerate(handle) << "\n" << std::flush;
  std::vector<float> output(4096);
  for(int i=0;i<10;i++) engine.mix(output.data(),2048);
  std::cout << "混音完成\n";
  engine.stopAll();
  engine.deinit();
}
