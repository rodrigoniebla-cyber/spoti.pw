// The visualiser over the player's cover. Either look's PlayerGestures.x hands over Spotify's
// CoverArtTiltView (_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView): its single tap, which
// is Spotify's way into the tilt mode, and its layout. With the visualiser on, the tap switches between
// the cover and the visualiser instead, and the choice holds for every cover and the next launch.
//
// The player's cover is 354pt; the bar's is 40, so anything under 200 is left alone. Each tilt view gets
// one visualiser, on top, the size of the tilt view and rounded like the cover's image under it, which
// also hands it the cover for its background and colours. The visualiser takes no touches, so the next
// tap reaches the tilt view again. The player's list holds a cover per track in the queue; the view only
// draws while it is on the screen (VisualizerView.m).
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Visualizer.h"

static const CGFloat kPlayerCoverMinWidth = 200;
static const NSTimeInterval kFade = 0.35;
static char kVisualizerKey;

static NSHashTable<SGVisualizerView *> *sg_views;

static BOOL shown(void) {
    return SGFlag(SGKeyVisualizerShown, NO);
}

// The cover's image: the largest image view with an image inside the tilt view.
static UIImageView *coverImageView(UIView *root) {
    UIImageView *best = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < 200; i++) {
        UIView *view = queue[i];
        if ([view isKindOfClass:UIImageView.class] && !view.hidden && ((UIImageView *)view).image && ![view isKindOfClass:SGVisualizerView.class]) {
            if (!best || view.bounds.size.width * view.bounds.size.height > best.bounds.size.width * best.bounds.size.height) best = (UIImageView *)view;
        }
        for (UIView *child in view.subviews) {
            if (![child isKindOfClass:SGVisualizerView.class]) [queue addObject:child];
        }
    }
    return best;
}

static CGFloat cornerRadius(UIView *from, UIView *root) {
    CGFloat radius = 0;
    for (UIView *view = from; view && view != root.superview; view = view.superview) radius = MAX(radius, view.layer.cornerRadius);
    return radius;
}

void SGVisualizerCoverLaidOut(UIView *tiltView) {
    SGVisualizerView *visualizer = objc_getAssociatedObject(tiltView, &kVisualizerKey);
    BOOL wanted = SGFlag(SGKeyVisualizer, NO) && tiltView.bounds.size.width >= kPlayerCoverMinWidth;
    if (!wanted) {
        if (visualizer) {
            [visualizer removeFromSuperview];
            objc_setAssociatedObject(tiltView, &kVisualizerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!visualizer) {
        visualizer = [[SGVisualizerView alloc] initWithFrame:tiltView.bounds];
        visualizer.alpha = shown() ? 1 : 0;
        visualizer.layer.cornerCurve = kCACornerCurveContinuous;
        visualizer.clipsToBounds = YES;
        objc_setAssociatedObject(tiltView, &kVisualizerKey, visualizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sg_views) sg_views = [NSHashTable weakObjectsHashTable];
        [sg_views addObject:visualizer];
    }
    if (visualizer.superview != tiltView || tiltView.subviews.lastObject != visualizer) [tiltView addSubview:visualizer];
    UIImageView *image = coverImageView(tiltView);
    // Where the cover's image is drawn, which is not always the tilt view's whole bounds.
    CGRect frame = image ? [image convertRect:image.bounds toView:tiltView] : tiltView.bounds;
    if (CGRectGetWidth(frame) < kPlayerCoverMinWidth) frame = tiltView.bounds;
    if (!CGRectEqualToRect(visualizer.frame, frame)) visualizer.frame = frame;
    visualizer.layer.cornerRadius = image ? cornerRadius(image, tiltView) : 8;
    if (image.image) visualizer.artwork = image.image;
}

BOOL SGVisualizerCoverTapped(UIView *tiltView) {
    if (!SGFlag(SGKeyVisualizer, NO) || tiltView.bounds.size.width < kPlayerCoverMinWidth) return NO;
    BOOL now = !shown();
    SGSetEnabled(SGKeyVisualizerShown, now);
    SGVisualizerCoverLaidOut(tiltView);
    for (SGVisualizerView *view in sg_views) {
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : kFade animations:^{ view.alpha = now ? 1 : 0; }];
    }
    SGLog(@"visualizer: %@", now ? @"shown over the cover" : @"cover shown again");
    return YES;
}
