// One still of the visualizer (Visualizer.h), for the lock screen's artwork: the cover blurred behind,
// the cover itself as a circle in the middle and the bars round it, as the ring in the player draws them
// (SGVisualizerView.m), in its style, colour and mirror. With a line to show, the ring moves up and the
// line and the next one sit under it. Drawn with an image renderer, which any thread may use.
#import "Core/SGCore.h"
#import "Visualizer.h"

static void drawText(NSString *text, UIFont *font, UIColor *color, CGRect box) {
    if (!text.length) return;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    [text drawWithRect:box options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: paragraph}
               context:nil];
}

UIImage *SGVisualizerDrawFrame(CGFloat side, UIImage *cover, UIImage *backdrop, const float *bars, NSInteger bands,
                               UIColor *accent, NSString *line, NSString *next) {
    SGVisualizerStyle style = (SGVisualizerStyle)SGInt(SGKeyVisualizerStyle, SGVisualizerStyleBars);
    SGVisualizerColor colour = (SGVisualizerColor)SGInt(SGKeyVisualizerColor, SGVisualizerColorAccent);
    BOOL mirror = SGEnabled(SGKeyVisualizerMirror);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    CGSize size = CGSizeMake(side, side);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *renderer) {
        CGContextRef context = renderer.CGContext;
        CGRect bounds = (CGRect){CGPointZero, size};
        [UIColor.blackColor setFill];
        UIRectFill(bounds);
        if (backdrop) {
            [backdrop drawInRect:bounds];
            [[UIColor colorWithWhite:0 alpha:0.45] setFill];
            UIRectFillUsingBlendMode(bounds, kCGBlendModeNormal);
        }

        BOOL lyrics = line.length > 0;
        CGPoint centre = CGPointMake(side / 2, lyrics ? side * 0.39 : side / 2);
        CGFloat outer = side * (lyrics ? 0.33 : 0.45);
        CGFloat radius = outer * 0.62;   // the cover's, as the player's ring keeps it to 64 % of the square
        CGFloat inner = radius + side * 0.012;
        CGFloat reach = outer - inner;

        // The cover, a circle.
        CGRect coverBox = CGRectMake(centre.x - radius, centre.y - radius, radius * 2, radius * 2);
        CGContextSaveGState(context);
        CGContextSetShadowWithColor(context, CGSizeMake(0, side * 0.01), side * 0.04, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
        [[UIColor colorWithWhite:0.12 alpha:1] setFill];
        CGContextFillEllipseInRect(context, coverBox);
        CGContextRestoreGState(context);
        if (cover) {
            CGContextSaveGState(context);
            CGContextAddEllipseInRect(context, coverBox);
            CGContextClip(context);
            [cover drawInRect:coverBox];
            CGContextRestoreGState(context);
        }

        // The bars round it.
        NSInteger count = mirror ? bands * 2 : bands;
        if (count > 0 && reach > 0 && bars) {
            CGFloat step = 2 * M_PI / count;
            CGFloat width = MAX(2, MIN(side * 0.014, inner * step * 0.55));
            UIColor *plain = colour == SGVisualizerColorWhite ? UIColor.whiteColor : (accent ?: UIColor.whiteColor);
            CGContextSetLineCap(context, kCGLineCapRound);
            CGContextSetLineJoin(context, kCGLineJoinRound);
            UIBezierPath *wave = style == SGVisualizerStyleWave ? [UIBezierPath bezierPath] : nil;
            for (NSInteger i = 0; i < count; i++) {
                NSInteger band = mirror ? (i < bands ? i : count - 1 - i) : i;
                CGFloat value = MAX(0, MIN(1, bars[band]));
                CGFloat angle = -M_PI_2 + (i + 0.5) * step;
                CGFloat dx = cos(angle), dy = sin(angle);
                CGFloat out = inner + MAX(width * 0.5, value * reach);
                CGPoint from = CGPointMake(centre.x + dx * inner, centre.y + dy * inner);
                CGPoint to = CGPointMake(centre.x + dx * out, centre.y + dy * out);
                UIColor *color = colour == SGVisualizerColorSpectrum
                    ? [UIColor colorWithHue:(CGFloat)i / count saturation:0.75 brightness:1 alpha:1] : plain;
                switch (style) {
                    case SGVisualizerStyleBars:
                        [color setStroke];
                        CGContextSetLineWidth(context, width);
                        CGContextMoveToPoint(context, from.x, from.y);
                        CGContextAddLineToPoint(context, to.x, to.y);
                        CGContextStrokePath(context);
                        break;
                    case SGVisualizerStyleDots:
                        [color setFill];
                        CGContextFillEllipseInRect(context, CGRectMake(to.x - width * 0.6, to.y - width * 0.6, width * 1.2, width * 1.2));
                        break;
                    case SGVisualizerStyleWave:
                        if (i == 0) [wave moveToPoint:to];
                        else [wave addLineToPoint:to];
                        break;
                }
            }
            if (wave) {
                [wave closePath];
                wave.lineWidth = MAX(2, side * 0.006);
                wave.lineJoinStyle = kCGLineJoinRound;
                [(colour == SGVisualizerColorSpectrum ? UIColor.whiteColor : plain) setStroke];
                [wave stroke];
            }
        }

        // The line being sung, and the next one dimmer, under the ring.
        if (lyrics) {
            CGFloat margin = side * 0.07, top = centre.y + outer + side * 0.04;
            CGFloat lineHeight = side * 0.17;
            drawText(line, [UIFont systemFontOfSize:side * 0.058 weight:UIFontWeightBold], UIColor.whiteColor,
                     CGRectMake(margin, top, side - 2 * margin, lineHeight));
            drawText(next, [UIFont systemFontOfSize:side * 0.04 weight:UIFontWeightBold], [UIColor colorWithWhite:1 alpha:0.45],
                     CGRectMake(margin, top + lineHeight + side * 0.01, side - 2 * margin, side - top - lineHeight - margin));
        }
    }];
}
