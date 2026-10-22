#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <android/choreographer.h>
#include <android/log.h>
#include <dlfcn.h>
#include <time.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <map>
#include <atomic>
#include <jni.h>
#include <vector>

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "PILI_PACING", __VA_ARGS__)
static int64_t now_ns() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec*1000000000LL+t.tv_nsec; }
using Dlsym = void*(*)(void*,const char*);
static Dlsym real_dlsym() { return reinterpret_cast<Dlsym>(dlvsym(RTLD_NEXT,"dlsym","LIBC")); }
static int mode = 0;
static constexpr int64_t period = 8333333;
struct Timeline { int64_t start=0, expected=0, deadline=0, id=0; };
static std::mutex timeline_mutex;
static Timeline latest;
struct Plan { Timeline timeline; int64_t cookie=0; };
static std::deque<Plan> plans;
static std::map<int64_t,Timeline> history;
static thread_local Plan raster_plan;
static thread_local Timeline ui_timeline;
extern "C" __attribute__((visibility("default"))) int64_t pili_frame_expected(int64_t target_us) {
  std::lock_guard<std::mutex> lock(timeline_mutex);
  auto it=history.find(target_us);
  return it==history.end()?target_us:it->second.expected/1000;
}
struct Callback { AChoreographer_frameCallback64 cb; void* data; };
static void frame_callback(const AChoreographerFrameCallbackData* data, void* value) {
  auto* original = static_cast<Callback*>(value);
  size_t index = AChoreographerFrameCallbackData_getPreferredFrameTimelineIndex(data);
  if((mode==7 || mode==8) && index+1<AChoreographerFrameCallbackData_getFrameTimelinesLength(data)) ++index;
  if(mode>=9) {
    const auto start=AChoreographerFrameCallbackData_getFrameTimeNanos(data);
    for(size_t i=0;i<AChoreographerFrameCallbackData_getFrameTimelinesLength(data);++i) {
      if(AChoreographerFrameCallbackData_getFrameTimelineExpectedPresentationTimeNanos(data,i)>=start+period*4-1000000) {index=i;break;}
    }
  }
  Timeline t{AChoreographerFrameCallbackData_getFrameTimeNanos(data),
    AChoreographerFrameCallbackData_getFrameTimelineExpectedPresentationTimeNanos(data,index),
    AChoreographerFrameCallbackData_getFrameTimelineDeadlineNanos(data,index),
    AChoreographerFrameCallbackData_getFrameTimelineVsyncId(data,index)};
  { std::lock_guard<std::mutex> lock(timeline_mutex); latest=t; history[(t.start+period)/1000]=t; if(history.size()>180) history.erase(history.begin()); }
  LOG("vsync %lld %lld %lld %lld %lld",(long long)t.start,(long long)t.expected,(long long)t.deadline,(long long)t.id,(long long)now_ns());
  // 保留旧引擎运动时钟，单独测量输出层时间戳的作用。
  ui_timeline=t; original->cb(t.start,original->data);
  delete original;
}
static void post_callback(AChoreographer* c,AChoreographer_frameCallback64 cb,void* data) {
  AChoreographer_postVsyncCallback(c,frame_callback,new Callback{cb,data});
}
using ReadProperty = char*(*)(void*,const char*);
static ReadProperty read_property;
static char* timed_property(void* context,const char* name) {
  auto start=now_ns(); auto value=read_property(context,name); auto end=now_ns();
  if(end-start>1000000 && (!strcmp(name,"playlist-pos") || !strcmp(name,"speed") || !strcmp(name,"time-pos") || !strcmp(name,"pause") || !strcmp(name,"paused-for-cache") || !strcmp(name,"seeking") || !strcmp(name,"eof-reached")))
    LOG("property %s %lld %lld",name,(long long)start,(long long)end);
  return value;
}
extern "C" void* dlsym(void* handle,const char* name) {
  auto fn=real_dlsym();
  if(!strcmp(name,"mpv_get_property_string")) {read_property=reinterpret_cast<ReadProperty>(fn(handle,name));return reinterpret_cast<void*>(timed_property);}
  if (!strcmp(name,"AChoreographer_postFrameCallback64")) return reinterpret_cast<void*>(post_callback);
  return fn(handle,name);
}
struct Pending { EGLuint64KHR id; int64_t start,end,target,expected,desired; bool set; };
struct SurfaceState { EGLSurface surface=EGL_NO_SURFACE; std::deque<Pending> frames; };
static thread_local SurfaceState state;
extern "C" EGLBoolean eglSwapBuffers(EGLDisplay display,EGLSurface surface) {
  using Swap=EGLBoolean(*)(EGLDisplay,EGLSurface);
  static auto swap=reinterpret_cast<Swap>(real_dlsym()(RTLD_NEXT,"eglSwapBuffers"));
  char thread_name[16]={}; prctl(PR_GET_NAME,thread_name);
  if (!strstr(thread_name,".raster")) return swap(display,surface);
  static auto present=reinterpret_cast<PFNEGLPRESENTATIONTIMEANDROIDPROC>(eglGetProcAddress("eglPresentationTimeANDROID"));
  static auto next_id=reinterpret_cast<PFNEGLGETNEXTFRAMEIDANDROIDPROC>(eglGetProcAddress("eglGetNextFrameIdANDROID"));
  static auto timestamps=reinterpret_cast<PFNEGLGETFRAMETIMESTAMPSANDROIDPROC>(eglGetProcAddress("eglGetFrameTimestampsANDROID"));
  if (state.surface!=surface) {
    state.surface=surface; state.frames.clear();
    auto enabled=eglSurfaceAttrib(display,surface,EGL_TIMESTAMPS_ANDROID,EGL_TRUE);
    LOG("surface %p timestamps %d mode %d",surface,enabled,mode);
  }
  const EGLint names[]={EGL_DISPLAY_PRESENT_TIME_ANDROID,EGL_RENDERING_COMPLETE_TIME_ANDROID,EGL_COMPOSITION_LATCH_TIME_ANDROID};
  for(auto it=state.frames.begin();it!=state.frames.end();) {
    EGLnsecsANDROID values[3]={};
    if (timestamps && timestamps(display,surface,it->id,3,names,values) && values[0]!=EGL_TIMESTAMP_PENDING_ANDROID) {
      LOG("frame %llu %lld %lld %lld %lld %lld %d %lld %lld %lld",(unsigned long long)it->id,(long long)it->start,(long long)it->end,(long long)it->target,(long long)it->expected,(long long)it->desired,it->set,(long long)values[0],(long long)values[1],(long long)values[2]);
      it=state.frames.erase(it);
    } else if (state.frames.size()>90) {
      LOG("unresolved %llu",(unsigned long long)it->id); it=state.frames.erase(it);
    } else ++it;
  }
  Timeline t;
  { std::lock_guard<std::mutex> lock(timeline_mutex); t=mode>=8?raster_plan.timeline:latest; }
  Pending p{};
  p.start=now_ns(); p.target=t.start+period; p.expected=t.expected;
  p.desired=mode==1?p.target:mode==2?t.expected:mode==3?p.target+period:0;
  if(mode==4 || mode>=7) p.desired=t.expected-1000000;
  if (next_id) next_id(display,surface,&p.id);
  if(mode && p.desired>0 && present) p.set=present(display,surface,p.desired);
  auto result=swap(display,surface);
  p.end=now_ns();
  if(mode>=8) LOG("plan %llu %lld %lld %lld %lld %lld %lld",(unsigned long long)p.id,(long long)raster_plan.cookie,(long long)t.start,(long long)t.expected,(long long)t.deadline,(long long)p.start,(long long)p.end);
  state.frames.push_back(p);
  return result;
}
__attribute__((constructor)) static void initialize() {
  FILE* f=fopen("/data/user/0/io.github.wallpap.piliaurora.profile/cache/output-mode.txt","r");
  if(f) { fscanf(f,"%d",&mode); fclose(f); }
  LOG("loaded mode %d pid %d dlsym %d",mode,getpid(),real_dlsym()!=nullptr);
}

// 此处借用隔离包的 trace 边界传递身份；正式引擎应随 FrameItem 携带。
extern "C" ssize_t write(int fd,const void* data,size_t count) {
  using Write=ssize_t(*)(int,const void*,size_t);
  static auto fn=reinterpret_cast<Write>(real_dlsym()(RTLD_NEXT,"write"));
  if(mode>=8 && count>5 && count<512) {
    char value[512]={}; memcpy(value,data,count);
    char type=0,name[256]={}; int pid=0; long long cookie=0;
    if(sscanf(value,"%c|%d|%255[^|]|%lld",&type,&pid,name,&cookie)>=3) {
      if(type=='F' && !strcmp(name,"PipelineProduce")) {
        std::lock_guard<std::mutex> lock(timeline_mutex);
        plans.push_back(Plan{ui_timeline,cookie});
      } else if(type=='B' && !strcmp(name,"Animator::DrawLastLayerTrees")) {
        std::lock_guard<std::mutex> lock(timeline_mutex);
        plans.push_back(Plan{ui_timeline,0});
      } else if(type=='B' && !strcmp(name,"Rasterizer::DrawToSurfaces")) {
        std::lock_guard<std::mutex> lock(timeline_mutex);
        if(plans.empty()) {raster_plan={}; LOG("plan_missing");}
        else {raster_plan=plans.front();plans.pop_front();}
      } else if(type=='F' && !strcmp(name,"PipelineItem") && raster_plan.cookie && cookie!=raster_plan.cookie) {
        LOG("plan_mismatch %lld %lld",cookie,(long long)raster_plan.cookie);
      }
    }
  }
  return fn(fd,data,count);
}

static std::atomic<int64_t> video_available{0}, video_consumed{0};
extern "C" JNIEXPORT jlong JNICALL Java_com_alexmercerind_media_1kit_1video_VideoSurfaceTexture_pacingRequested(JNIEnv*,jclass) {
  auto sequence=++video_available; LOG("video_request %lld %lld",(long long)sequence,(long long)now_ns());return sequence;
}
extern "C" JNIEXPORT void JNICALL Java_com_alexmercerind_media_1kit_1video_VideoSurfaceTexture_pacingConsumed(JNIEnv*,jclass,jlong sequence,jlong timestamp) {
  video_consumed.store(sequence); LOG("video_consume %lld %lld %lld",(long long)sequence,(long long)now_ns(),(long long)timestamp);
}
extern "C" __attribute__((visibility("default"))) int32_t pili_video_dirty() {
  return video_available.load()!=video_consumed.load();
}
