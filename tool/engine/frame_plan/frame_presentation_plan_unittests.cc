#include "flutter/flow/frame_timings.h"
#include "flutter/flow/surface_frame.h"
#include "flutter/flow/layers/layer_tree.h"
#include "flutter/flow/layers/texture_layer.h"
#include "flutter/flow/layers/container_layer.h"
#include "gtest/gtest.h"

namespace flutter {

namespace {
class ContentTexture final : public Texture {
 public:
  ContentTexture() : Texture(7) {}
  bool dirty = false;
  bool HasNewFrame() override { return dirty; }
  void MarkNewFrameAvailable() override { dirty = true; }
  void OnTextureUnregistered() override {}
  void OnGrContextCreated() override {}
  void OnGrContextDestroyed() override {}
  void Paint(PaintContext&, const DlRect&, bool, DlImageSampling) override {
    dirty = false;
  }
};
}  // namespace

TEST(FramePresentationPlanTest, RasterRetryRetainsFrameAndTimelineIdentity) {
  FrameTimingsRecorder recorder;
  const auto now = fml::TimePoint::Now();
  const auto feedback = std::make_shared<FramePresentationFeedback>();
  auto plan = std::make_shared<const FramePresentationPlan>(
      FramePresentationPlan{17, 100, 500, 400, 120, 100, feedback});
  recorder.RecordVsync(now, now);
  recorder.SetPresentationPlan(plan);
  recorder.RecordBuildStart(now);
  recorder.RecordBuildEnd(now);
  recorder.RecordRasterStart(now);
  recorder.RecordRasterEnd();
  auto retry = recorder.CloneUntil(FrameTimingsRecorder::State::kBuildEnd);
  EXPECT_EQ(retry->GetFrameNumber(), recorder.GetFrameNumber());
  EXPECT_EQ(retry->GetPresentationPlan(), plan);
  EXPECT_EQ(retry->GetPresentationPlan()->vsync_id, 17);
  EXPECT_EQ(retry->GetPresentationPlan()->expected_ns, 500);
  feedback->Observe(5000);
  EXPECT_EQ(retry->GetPresentationPlan()->expected_ns, 500);
  SurfaceFrame::SubmitInfo first_view;
  first_view.presentation_plan = plan;
  SurfaceFrame::SubmitInfo retried_view;
  retried_view.presentation_plan = retry->GetPresentationPlan();
  EXPECT_EQ(first_view.presentation_plan, retried_view.presentation_plan);
}

TEST(FramePresentationPlanTest, ContentDamageUsesUnconsumedTextureAndGeometry) {
  TextureRegistry textures;
  auto texture = std::make_shared<ContentTexture>();
  textures.RegisterTexture(texture);
  auto tree = [](float x, bool freeze = false) {
    return std::make_unique<LayerTree>(std::make_shared<TextureLayer>(
        DlPoint{x, 0}, DlSize{20, 20}, 7, freeze, DlImageSampling::kLinear),
        DlISize{100, 100});
  };
  auto changed = [&](LayerTree& current, const LayerTree* previous) {
    FrameDamage damage;
    damage.SetPreviousLayerTree(previous);
    damage.SetTextureRegistry(&textures);
    damage.ComputeClipRect(current, false, false);
    return !damage.GetFrameDamage()->IsEmpty();
  };
  auto first = tree(0);
  EXPECT_TRUE(changed(*first, nullptr));
  auto retained = tree(0);
  EXPECT_FALSE(changed(*retained, first.get()));
  texture->MarkNewFrameAvailable();
  auto video = tree(0);
  EXPECT_TRUE(changed(*video, retained.get()));
  texture->dirty = false;
  EXPECT_FALSE(changed(*video, video.get()));
  texture->dirty = true;
  EXPECT_TRUE(changed(*video, video.get()));
  texture->dirty = false;
  auto consumed = tree(0);
  EXPECT_FALSE(changed(*consumed, video.get()));
  auto moved = tree(1);
  EXPECT_TRUE(changed(*moved, consumed.get()));
  auto rebuilt_surface = tree(1);
  EXPECT_TRUE(changed(*rebuilt_surface, nullptr));
  auto frozen = tree(1, true);
  EXPECT_TRUE(changed(*frozen, moved.get()));
  texture->dirty = true;
  auto still_frozen = tree(1, true);
  EXPECT_FALSE(changed(*still_frozen, frozen.get()));
}


TEST(FramePresentationPlanTest, ContentDamageInitializesPreviouslyUntrackedTree) {
  auto child = std::make_shared<ContainerLayer>();
  child->Add(std::make_shared<TextureLayer>(DlPoint{0, 0}, DlSize{20, 20},
                                           7, false, DlImageSampling::kLinear));
  auto root = std::make_shared<ContainerLayer>();
  root->Add(child);
  LayerTree untracked(root, DlISize{100, 100});
  LayerTree current(root, DlISize{100, 100});
  FrameDamage damage;
  damage.SetPreviousLayerTree(&untracked);
  damage.ComputeClipRect(current, false, false);
  EXPECT_FALSE(damage.GetFrameDamage()->IsEmpty());
}

}  // namespace flutter
