#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

// Helper to save CGImage to PNG file
BOOL saveCGImageToPNG(CGImageRef image, NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!dest) return NO;
    CGImageDestinationAddImage(dest, image, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok;
}

// Helper to create resized CGImage
CGImageRef createResizedImage(CGImageRef source, size_t targetWidth, size_t targetHeight) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, targetWidth, targetHeight, 8, targetWidth * 4, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, targetWidth, targetHeight), source);
    CGImageRef result = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(colorSpace);
    return result;
}

// Helper to draw radial glow
void drawRadialGlow(CGContextRef ctx, CGPoint center, CGFloat innerR, CGFloat outerR, CGFloat r, CGFloat g, CGFloat b, CGFloat maxA) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat colors[] = {
        r, g, b, maxA,
        r, g, b, 0.0
    };
    CGFloat locations[] = { 0.0, 1.0 };
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, colors, locations, 2);
    CGContextDrawRadialGradient(ctx, grad, center, innerR, center, outerR, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
}

// Helper to draw linear gradient in a path
void fillPathWithLinearGradient(CGContextRef ctx, CGPathRef path, CGPoint start, CGPoint end, const CGFloat *colors, const CGFloat *locations, size_t count) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, colors, locations, count);
    CGContextDrawLinearGradient(ctx, grad, start, end, 0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    CGContextRestoreGState(ctx);
}

// Helper to draw radial gradient in a path
void fillPathWithRadialGradient(CGContextRef ctx, CGPathRef path, CGPoint startCenter, CGFloat startRadius, CGPoint endCenter, CGFloat endRadius, const CGFloat *colors, const CGFloat *locations, size_t count) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, colors, locations, count);
    CGContextDrawRadialGradient(ctx, grad, startCenter, startRadius, endCenter, endRadius, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    CGContextRestoreGState(ctx);
}

// -------------------------------------------------------------
// OPTION A: The Relay Convergence Nexus (Recommended Primary)
// -------------------------------------------------------------
CGImageRef renderOptionA(void) {
    size_t W = 1024;
    size_t H = 1024;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetAllowsAntialiasing(ctx, YES);
    CGContextSetShouldAntialias(ctx, YES);

    CGPoint center = CGPointMake(512, 512);

    // 1. Ambient Backdrop Glow
    drawRadialGlow(ctx, center, 0, 460, 0.22, 0.74, 0.97, 0.16);
    drawRadialGlow(ctx, center, 0, 320, 0.12, 0.35, 0.95, 0.14);

    // 2. Outer Orbital Tracking Ring (Subtle precision telemetry)
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 12);
    CGFloat dash1[] = { 14, 18 };
    CGContextSetLineDash(ctx, 0, dash1, 2);
    CGContextSetRGBStrokeColor(ctx, 0.15, 0.22, 0.40, 0.50);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - 330, center.y - 330, 660, 660));
    
    // Thin sharp cyan track
    CGContextSetLineWidth(ctx, 3);
    CGContextSetLineDash(ctx, 0, NULL, 0);
    CGContextSetRGBStrokeColor(ctx, 0.22, 0.74, 0.97, 0.35);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - 330, center.y - 330, 660, 660));
    CGContextRestoreGState(ctx);

    // 3. Three Inward Convergence Conduits (120 deg symmetry)
    // Nodes at radius 330:
    // Top node: angle = -90 deg (or 270) -> (512, 512 - 330) = (512, 182)
    // Bottom-Right: angle = 30 deg -> (512 + 330*cos(30), 512 + 330*sin(30)) = (797.7, 677.0)
    // Bottom-Left: angle = 150 deg -> (512 - 330*cos(30), 512 + 330*sin(30)) = (226.3, 677.0)

    for (int i = 0; i < 3; i++) {
        CGFloat angleDeg = -90.0 + i * 120.0;
        CGFloat rad = angleDeg * M_PI / 180.0;

        CGContextSaveGState(ctx);
        // Translate to center, rotate, translate back
        CGContextTranslateCTM(ctx, center.x, center.y);
        CGContextRotateCTM(ctx, rad + M_PI_2); // rotate so 0 deg points upwards
        CGContextTranslateCTM(ctx, -center.x, -center.y);

        // Shadow under conduit
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -12), 18, [[NSColor colorWithCalibratedRed:0.02 green:0.04 blue:0.12 alpha:0.6] CGColor]);

        // Draw conduit arm
        CGMutablePathRef armPath = CGPathCreateMutable();
        CGPathMoveToPoint(armPath, NULL, 482, 182);
        CGPathAddCurveToPoint(armPath, NULL, 482, 300, 466, 380, 440, 440);
        CGPathAddLineToPoint(armPath, NULL, 512, 420);
        CGPathAddLineToPoint(armPath, NULL, 584, 440);
        CGPathAddCurveToPoint(armPath, NULL, 558, 380, 542, 300, 542, 182);
        CGPathCloseSubpath(armPath);

        CGFloat armColors[] = {
            0.22, 0.74, 0.97, 0.95,   // cyan top
            0.08, 0.38, 0.88, 0.90,   // cobalt blue
            0.05, 0.08, 0.22, 0.95    // deep midnight navy
        };
        CGFloat armLocs[] = { 0.0, 0.5, 1.0 };
        fillPathWithLinearGradient(ctx, armPath, CGPointMake(512, 182), CGPointMake(512, 440), armColors, armLocs, 3);

        // Center optical data beam inside conduit
        CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL); // clear shadow
        CGContextSetLineWidth(ctx, 10);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetRGBStrokeColor(ctx, 0.88, 0.96, 1.0, 0.85);
        CGContextMoveToPoint(ctx, 512, 182);
        CGContextAddLineToPoint(ctx, 512, 435);
        CGContextStrokePath(ctx);

        CGPathRelease(armPath);
        CGContextRestoreGState(ctx);
    }

    // 4. Three Terminal Satellite Nodes
    CGFloat nodeAngles[] = { -90.0, 30.0, 150.0 };
    for (int i = 0; i < 3; i++) {
        CGFloat rad = nodeAngles[i] * M_PI / 180.0;
        CGPoint np = CGPointMake(center.x + 330 * cos(rad), center.y + 330 * sin(rad));

        CGContextSaveGState(ctx);
        // Physical shadow
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -14), 20, [[NSColor colorWithCalibratedRed:0.01 green:0.03 blue:0.10 alpha:0.7] CGColor]);

        // Outer node chassis (circle r = 66)
        CGRect nodeRect = CGRectMake(np.x - 66, np.y - 66, 132, 132);
        CGMutablePathRef npPath = CGPathCreateMutable();
        CGPathAddEllipseInRect(npPath, NULL, nodeRect);

        CGFloat nodeColors[] = {
            0.88, 0.96, 1.00, 1.0,
            0.22, 0.74, 0.97, 1.0,
            0.04, 0.38, 0.85, 1.0,
            0.03, 0.08, 0.22, 1.0
        };
        CGFloat nodeLocs[] = { 0.0, 0.35, 0.75, 1.0 };
        fillPathWithRadialGradient(ctx, npPath, CGPointMake(np.x - 16, np.y - 16), 5, np, 66, nodeColors, nodeLocs, 4);

        // Beveled precision rim
        CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
        CGContextSetLineWidth(ctx, 4);
        CGContextSetRGBStrokeColor(ctx, 0.9, 0.97, 1.0, 0.6);
        CGContextStrokeEllipseInRect(ctx, nodeRect);

        // Core satellite focal lens
        CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.95);
        CGContextFillEllipseInRect(ctx, CGRectMake(np.x - 24, np.y - 24, 48, 48));

        CGContextSetRGBFillColor(ctx, 0.02, 0.45, 0.85, 1.0);
        CGContextFillEllipseInRect(ctx, CGRectMake(np.x - 14, np.y - 14, 28, 28));

        CGPathRelease(npPath);
        CGContextRestoreGState(ctx);
    }

    // 5. Central Relay Master Hub
    CGContextSaveGState(ctx);
    // Powerful deep ambient & directional drop shadow for macOS dock depth
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -22), 32, [[NSColor colorWithCalibratedRed:0.01 green:0.03 blue:0.10 alpha:0.75] CGColor]);

    // Outer Hub Rim (r = 208)
    CGRect hubRect = CGRectMake(center.x - 208, center.y - 208, 416, 416);
    CGMutablePathRef hubPath = CGPathCreateMutable();
    CGPathAddEllipseInRect(hubPath, NULL, hubRect);

    CGFloat hubRimColors[] = {
        0.25, 0.75, 0.98, 1.0,   // Highlighting top-left
        0.10, 0.30, 0.75, 1.0,
        0.05, 0.08, 0.20, 1.0,   // Deep rich navy
        0.08, 0.20, 0.55, 1.0,
        0.35, 0.85, 0.98, 1.0
    };
    CGFloat hubRimLocs[] = { 0.0, 0.25, 0.60, 0.85, 1.0 };
    fillPathWithLinearGradient(ctx, hubPath, CGPointMake(hubRect.origin.x, hubRect.origin.y), CGPointMake(hubRect.origin.x + 416, hubRect.origin.y + 416), hubRimColors, hubRimLocs, 5);

    // Rim highlight bevel
    CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
    CGContextSetLineWidth(ctx, 4);
    CGContextSetRGBStrokeColor(ctx, 0.9, 0.96, 1.0, 0.6);
    CGContextStrokeEllipseInRect(ctx, hubRect);

    // Recessed Inner Station Bed (r = 180)
    CGRect bedRect = CGRectMake(center.x - 180, center.y - 180, 360, 360);
    CGMutablePathRef bedPath = CGPathCreateMutable();
    CGPathAddEllipseInRect(bedPath, NULL, bedRect);
    CGFloat bedColors[] = {
        0.12, 0.16, 0.32, 1.0,
        0.04, 0.06, 0.15, 1.0,
        0.02, 0.03, 0.08, 1.0
    };
    CGFloat bedLocs[] = { 0.0, 0.5, 1.0 };
    fillPathWithRadialGradient(ctx, bedPath, CGPointMake(center.x - 40, center.y - 40), 10, center, 180, bedColors, bedLocs, 3);
    CGPathRelease(bedPath);

    // Precision Inner Telemetry Ring (r = 148, dashed tick marks)
    CGContextSetLineWidth(ctx, 8);
    CGFloat dashTicks[] = { 8, 18 };
    CGContextSetLineDash(ctx, 0, dashTicks, 2);
    CGContextSetRGBStrokeColor(ctx, 0.22, 0.74, 0.97, 0.65);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - 148, center.y - 148, 296, 296));

    // Secondary Telemetry Ring (r = 118)
    CGContextSetLineWidth(ctx, 12);
    CGFloat dashArc[] = { 45, 65 };
    CGContextSetLineDash(ctx, 0, dashArc, 2);
    CGContextSetRGBStrokeColor(ctx, 0.12, 0.45, 0.95, 0.75);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - 118, center.y - 118, 236, 236));

    // Relay Pulse Nucleus (r = 80)
    CGContextSetLineDash(ctx, 0, NULL, 0); // solid
    CGRect pulseRect = CGRectMake(center.x - 80, center.y - 80, 160, 160);
    CGMutablePathRef pulsePath = CGPathCreateMutable();
    CGPathAddEllipseInRect(pulsePath, NULL, pulseRect);
    CGFloat pulseColors[] = {
        1.00, 1.00, 1.00, 1.0,   // Brilliant white heart
        0.70, 0.90, 1.00, 1.0,
        0.22, 0.74, 0.97, 1.0,   // Electric cyan
        0.05, 0.40, 0.85, 1.0,   // Pure cobalt
        0.02, 0.15, 0.45, 1.0
    };
    CGFloat pulseLocs[] = { 0.0, 0.25, 0.55, 0.85, 1.0 };
    fillPathWithRadialGradient(ctx, pulsePath, CGPointMake(center.x - 18, center.y - 18), 5, center, 80, pulseColors, pulseLocs, 5);

    // Rim around nucleus
    CGContextSetLineWidth(ctx, 3);
    CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 0.8);
    CGContextStrokeEllipseInRect(ctx, pulseRect);

    // Solid geometric core aperture (r = 38 & 22) - vital for crisp 16x16 clarity
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.98);
    CGContextFillEllipseInRect(ctx, CGRectMake(center.x - 38, center.y - 38, 76, 76));

    CGContextSetRGBFillColor(ctx, 0.02, 0.25, 0.65, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(center.x - 22, center.y - 22, 44, 44));

    // Native macOS Glass Specular Crescent (Restrained top-half sheen)
    CGMutablePathRef sheenPath = CGPathCreateMutable();
    CGPathMoveToPoint(sheenPath, NULL, center.x - 145, center.y - 50);
    CGPathAddCurveToPoint(sheenPath, NULL, center.x - 100, center.y - 120, center.x + 100, center.y - 120, center.x + 145, center.y - 50);
    CGPathAddCurveToPoint(sheenPath, NULL, center.x + 80, center.y - 95, center.x - 80, center.y - 95, center.x - 145, center.y - 50);
    CGPathCloseSubpath(sheenPath);

    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.28);
    CGContextAddPath(ctx, sheenPath);
    CGContextFillPath(ctx);
    CGPathRelease(sheenPath);

    CGPathRelease(pulsePath);
    CGPathRelease(hubPath);
    CGContextRestoreGState(ctx);

    CGImageRef finalImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return finalImg;
}

// -------------------------------------------------------------
// OPTION B: The Quad-Bridge Cross Relay (Enterprise Switchboard)
// -------------------------------------------------------------
CGImageRef renderOptionB(void) {
    size_t W = 1024;
    size_t H = 1024;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetAllowsAntialiasing(ctx, YES);
    CGContextSetShouldAntialias(ctx, YES);

    CGPoint center = CGPointMake(512, 512);

    // 1. Ambient Glow
    drawRadialGlow(ctx, center, 0, 460, 0.22, 0.74, 0.97, 0.16);

    // 2. Diagonal Telemetry Ring
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 18);
    CGFloat dashB[] = { 24, 32 };
    CGContextSetLineDash(ctx, 0, dashB, 2);
    CGContextSetRGBStrokeColor(ctx, 0.12, 0.18, 0.32, 0.6);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - 340, center.y - 340, 680, 680));
    CGContextRestoreGState(ctx);

    // 3. 4 Orthogonal Beams (Cross)
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -14), 22, [[NSColor colorWithCalibratedRed:0.02 green:0.04 blue:0.12 alpha:0.65] CGColor]);

    // Vertical beam
    CGRect vertRect = CGRectMake(512 - 50, 160, 100, 704);
    NSBezierPath *vertPath = [NSBezierPath bezierPathWithRoundedRect:NSRectFromCGRect(vertRect) xRadius:30 yRadius:30];
    CGPathRef vPath = [vertPath CGPath];
    CGFloat vColors[] = {
        0.22, 0.74, 0.97, 1.0,
        0.08, 0.35, 0.85, 1.0,
        0.04, 0.10, 0.25, 1.0,
        0.08, 0.35, 0.85, 1.0,
        0.22, 0.74, 0.97, 1.0
    };
    CGFloat vLocs[] = { 0.0, 0.25, 0.5, 0.75, 1.0 };
    fillPathWithLinearGradient(ctx, vPath, CGPointMake(512, 160), CGPointMake(512, 864), vColors, vLocs, 5);

    // Horizontal beam
    CGRect horizRect = CGRectMake(160, 512 - 50, 704, 100);
    NSBezierPath *horizPath = [NSBezierPath bezierPathWithRoundedRect:NSRectFromCGRect(horizRect) xRadius:30 yRadius:30];
    CGPathRef hPath = [horizPath CGPath];
    CGFloat hColors[] = {
        0.06, 0.75, 0.85, 1.0,
        0.12, 0.40, 0.90, 1.0,
        0.04, 0.10, 0.25, 1.0,
        0.12, 0.40, 0.90, 1.0,
        0.06, 0.75, 0.85, 1.0
    };
    CGFloat hLocs[] = { 0.0, 0.25, 0.5, 0.75, 1.0 };
    fillPathWithLinearGradient(ctx, hPath, CGPointMake(160, 512), CGPointMake(864, 512), hColors, hLocs, 5);

    CGContextRestoreGState(ctx);

    // 4. End Terminal Nodes (N, S, E, W)
    CGPoint endPoints[] = {
        CGPointMake(512, 180), CGPointMake(512, 844),
        CGPointMake(180, 512), CGPointMake(844, 512)
    };
    for (int i = 0; i < 4; i++) {
        CGPoint ep = endPoints[i];
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -10), 16, [[NSColor colorWithCalibratedRed:0.02 green:0.04 blue:0.12 alpha:0.6] CGColor]);

        CGContextSetRGBFillColor(ctx, 0.06, 0.10, 0.22, 1.0);
        CGContextFillEllipseInRect(ctx, CGRectMake(ep.x - 52, ep.y - 52, 104, 104));

        CGContextSetLineWidth(ctx, 8);
        CGContextSetRGBStrokeColor(ctx, 0.22, 0.74, 0.97, 0.9);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(ep.x - 52, ep.y - 52, 104, 104));

        CGContextSetRGBFillColor(ctx, 0.88, 0.96, 1.0, 1.0);
        CGContextFillEllipseInRect(ctx, CGRectMake(ep.x - 22, ep.y - 22, 44, 44));

        CGContextSetRGBFillColor(ctx, 0.05, 0.40, 0.85, 1.0);
        CGContextFillEllipseInRect(ctx, CGRectMake(ep.x - 12, ep.y - 12, 24, 24));
        CGContextRestoreGState(ctx);
    }

    // 5. Interlocking Center Hub
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -20), 30, [[NSColor colorWithCalibratedRed:0.01 green:0.03 blue:0.10 alpha:0.75] CGColor]);

    CGRect hubOuter = CGRectMake(center.x - 220, center.y - 220, 440, 440);
    CGMutablePathRef hubP = CGPathCreateMutable();
    CGPathAddEllipseInRect(hubP, NULL, hubOuter);
    CGFloat hbColors[] = {
        0.18, 0.24, 0.42, 1.0,
        0.06, 0.09, 0.20, 1.0,
        0.02, 0.04, 0.10, 1.0
    };
    CGFloat hbLocs[] = { 0.0, 0.5, 1.0 };
    fillPathWithRadialGradient(ctx, hubP, CGPointMake(center.x - 50, center.y - 50), 10, center, 220, hbColors, hbLocs, 3);

    CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
    CGContextSetLineWidth(ctx, 6);
    CGContextSetRGBStrokeColor(ctx, 0.75, 0.90, 1.0, 0.6);
    CGContextStrokeEllipseInRect(ctx, hubOuter);

    // Concentric Dashed Switch Track
    CGContextSetLineWidth(ctx, 16);
    CGFloat dashTrack[] = { 60, 30 };
    CGContextSetLineDash(ctx, 0, dashTrack, 2);
    CGContextSetRGBStrokeColor(ctx, 0.22, 0.74, 0.97, 0.8);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - 176, center.y - 176, 352, 352));

    // Deep well
    CGContextSetLineDash(ctx, 0, NULL, 0);
    CGContextSetRGBFillColor(ctx, 0.03, 0.06, 0.14, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(center.x - 136, center.y - 136, 272, 272));

    // Core Prism
    CGRect coreR = CGRectMake(center.x - 96, center.y - 96, 192, 192);
    CGMutablePathRef coreP = CGPathCreateMutable();
    CGPathAddEllipseInRect(coreP, NULL, coreR);
    CGFloat coreColors[] = {
        1.0, 1.0, 1.0, 1.0,
        0.45, 0.85, 1.0, 1.0,
        0.05, 0.45, 0.90, 1.0,
        0.02, 0.10, 0.30, 1.0
    };
    CGFloat coreLocs[] = { 0.0, 0.3, 0.7, 1.0 };
    fillPathWithRadialGradient(ctx, coreP, CGPointMake(center.x - 20, center.y - 20), 5, center, 96, coreColors, coreLocs, 4);

    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(center.x - 44, center.y - 44, 88, 88));

    CGContextSetRGBFillColor(ctx, 0.05, 0.40, 0.85, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(center.x - 24, center.y - 24, 48, 48));

    CGPathRelease(coreP);
    CGPathRelease(hubP);
    CGContextRestoreGState(ctx);

    CGImageRef finalImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return finalImg;
}

// -------------------------------------------------------------
// OPTION C: The Kinetic R-Relay (Orbital Data Spine)
// -------------------------------------------------------------
CGImageRef renderOptionC(void) {
    size_t W = 1024;
    size_t H = 1024;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetAllowsAntialiasing(ctx, YES);
    CGContextSetShouldAntialias(ctx, YES);

    CGPoint center = CGPointMake(512, 512);

    // 1. Ambient Glow
    drawRadialGlow(ctx, center, 0, 460, 0.22, 0.74, 0.97, 0.16);

    // 2. Halo ring
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 10);
    CGFloat dashC[] = { 16, 24 };
    CGContextSetLineDash(ctx, 0, dashC, 2);
    CGContextSetRGBStrokeColor(ctx, 0.15, 0.22, 0.38, 0.45);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - 340, center.y - 340, 680, 680));
    CGContextRestoreGState(ctx);

    // 3. Shadowed structure
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -18), 24, [[NSColor colorWithCalibratedRed:0.01 green:0.03 blue:0.10 alpha:0.65] CGColor]);

    // Vertical Mast
    CGRect mastRect = CGRectMake(300, 180, 110, 664);
    NSBezierPath *mastB = [NSBezierPath bezierPathWithRoundedRect:NSRectFromCGRect(mastRect) xRadius:55 yRadius:55];
    CGPathRef mastPath = [mastB CGPath];
    CGFloat mastColors[] = {
        0.88, 0.96, 1.00, 1.0,
        0.22, 0.74, 0.97, 1.0,
        0.10, 0.35, 0.85, 1.0,
        0.04, 0.08, 0.20, 1.0
    };
    CGFloat mastLocs[] = { 0.0, 0.25, 0.70, 1.0 };
    fillPathWithLinearGradient(ctx, mastPath, CGPointMake(355, 180), CGPointMake(355, 844), mastColors, mastLocs, 4);

    // Mast node terminals
    CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.95);
    CGContextFillEllipseInRect(ctx, CGRectMake(355 - 30, 235 - 30, 60, 60));
    CGContextSetRGBFillColor(ctx, 0.22, 0.74, 0.97, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(355 - 24, 789 - 24, 48, 48));

    // Upper Arch (Arch of R)
    CGMutablePathRef archPath = CGPathCreateMutable();
    CGPathMoveToPoint(archPath, NULL, 380, 200);
    CGPathAddCurveToPoint(archPath, NULL, 580, 200, 720, 250, 720, 400);
    CGPathAddCurveToPoint(archPath, NULL, 720, 540, 580, 590, 410, 590);
    CGPathAddLineToPoint(archPath, NULL, 410, 470);
    CGPathAddCurveToPoint(archPath, NULL, 520, 470, 600, 440, 600, 395);
    CGPathAddCurveToPoint(archPath, NULL, 600, 340, 500, 310, 380, 310);
    CGPathCloseSubpath(archPath);

    CGFloat archColors[] = {
        0.40, 0.90, 0.98, 1.0,
        0.08, 0.65, 0.92, 1.0,
        0.12, 0.25, 0.70, 1.0,
        0.04, 0.08, 0.20, 1.0
    };
    CGFloat archLocs[] = { 0.0, 0.4, 0.8, 1.0 };
    fillPathWithLinearGradient(ctx, archPath, CGPointMake(380, 200), CGPointMake(720, 590), archColors, archLocs, 4);

    // Diagonal Conduit (Leg of R)
    CGMutablePathRef legPath = CGPathCreateMutable();
    CGPathMoveToPoint(legPath, NULL, 440, 520);
    CGPathAddLineToPoint(legPath, NULL, 690, 810);
    CGPathAddCurveToPoint(legPath, NULL, 715, 840, 755, 840, 780, 815);
    CGPathAddCurveToPoint(legPath, NULL, 805, 790, 805, 750, 775, 720);
    CGPathAddLineToPoint(legPath, NULL, 535, 450);
    CGPathCloseSubpath(legPath);

    CGFloat legColors[] = {
        0.08, 0.65, 0.92, 1.0,
        0.15, 0.38, 0.95, 1.0,
        0.02, 0.45, 0.85, 1.0
    };
    CGFloat legLocs[] = { 0.0, 0.5, 1.0 };
    fillPathWithLinearGradient(ctx, legPath, CGPointMake(440, 520), CGPointMake(780, 815), legColors, legLocs, 3);

    // Center focal tracking hub
    CGContextSetRGBFillColor(ctx, 0.05, 0.10, 0.25, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(550 - 44, 400 - 44, 88, 88));

    CGContextSetLineWidth(ctx, 8);
    CGContextSetRGBStrokeColor(ctx, 0.22, 0.74, 0.97, 1.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(550 - 44, 400 - 44, 88, 88));

    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(550 - 20, 400 - 20, 40, 40));

    CGPathRelease(legPath);
    CGPathRelease(archPath);
    CGContextRestoreGState(ctx);

    CGImageRef finalImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return finalImg;
}

// -------------------------------------------------------------
// Helper to render preview with background (Light or Dark)
// -------------------------------------------------------------
CGImageRef renderOnBackground(CGImageRef icon, size_t size, BOOL isDark) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, size, size, 8, size * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);

    if (isDark) {
        // macOS Sonoma / Sequoia Dark Wallpaper tone
        CGContextSetRGBFillColor(ctx, 0.07, 0.09, 0.13, 1.0);
    } else {
        // macOS Clean Light Studio Grey tone
        CGContextSetRGBFillColor(ctx, 0.94, 0.95, 0.96, 1.0);
    }
    CGContextFillRect(ctx, CGRectMake(0, 0, size, size));

    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, size, size), icon);

    CGImageRef result = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return result;
}

int main(void) {
    @autoreleasepool {
        NSLog(@"Starting high-fidelity rendering pipeline...");

        // 1. Render Option A (Recommended Primary)
        CGImageRef imgA = renderOptionA();
        saveCGImageToPNG(imgA, @"assets/icons/Relay-AppIcon-1024.png");
        saveCGImageToPNG(imgA, @"assets/icons/Relay-AppIcon-OptionA-1024.png");

        // 2. Render Option B & C
        CGImageRef imgB = renderOptionB();
        saveCGImageToPNG(imgB, @"assets/icons/Relay-AppIcon-OptionB-1024.png");

        CGImageRef imgC = renderOptionC();
        saveCGImageToPNG(imgC, @"assets/icons/Relay-AppIcon-OptionC-1024.png");

        // 3. Multi-resolution scaled exports for Option A (16, 32, 128, 256, 512)
        size_t sizes[] = { 16, 32, 128, 256, 512 };
        for (int i = 0; i < 5; i++) {
            size_t s = sizes[i];
            CGImageRef scaled = createResizedImage(imgA, s, s);
            NSString *p = [NSString stringWithFormat:@"assets/icons/Relay-AppIcon-%zux%zu.png", s, s];
            saveCGImageToPNG(scaled, p);
            CGImageRelease(scaled);
        }

        // Multi-resolution for Option B and Option C previews
        for (int i = 0; i < 5; i++) {
            size_t s = sizes[i];
            CGImageRef scaledB = createResizedImage(imgB, s, s);
            NSString *pb = [NSString stringWithFormat:@"assets/icons/Relay-OptionB-%zux%zu.png", s, s];
            saveCGImageToPNG(scaledB, pb);
            CGImageRelease(scaledB);

            CGImageRef scaledC = createResizedImage(imgC, s, s);
            NSString *pc = [NSString stringWithFormat:@"assets/icons/Relay-OptionC-%zux%zu.png", s, s];
            saveCGImageToPNG(scaledC, pc);
            CGImageRelease(scaledC);
        }

        // 4. Light and Dark Background Previews (For inspection & presentation)
        CGImageRef lightPrevA = renderOnBackground(imgA, 1024, NO);
        saveCGImageToPNG(lightPrevA, @"assets/icons/Relay-AppIcon-Preview-Light.png");
        CGImageRelease(lightPrevA);

        CGImageRef darkPrevA = renderOnBackground(imgA, 1024, YES);
        saveCGImageToPNG(darkPrevA, @"assets/icons/Relay-AppIcon-Preview-Dark.png");
        CGImageRelease(darkPrevA);

        CGImageRef lightPrevB = renderOnBackground(imgB, 1024, NO);
        saveCGImageToPNG(lightPrevB, @"assets/icons/Relay-OptionB-Preview-Light.png");
        CGImageRelease(lightPrevB);

        CGImageRef darkPrevB = renderOnBackground(imgB, 1024, YES);
        saveCGImageToPNG(darkPrevB, @"assets/icons/Relay-OptionB-Preview-Dark.png");
        CGImageRelease(darkPrevB);

        CGImageRef lightPrevC = renderOnBackground(imgC, 1024, NO);
        saveCGImageToPNG(lightPrevC, @"assets/icons/Relay-OptionC-Preview-Light.png");
        CGImageRelease(lightPrevC);

        CGImageRef darkPrevC = renderOnBackground(imgC, 1024, YES);
        saveCGImageToPNG(darkPrevC, @"assets/icons/Relay-OptionC-Preview-Dark.png");
        CGImageRelease(darkPrevC);

        CGImageRelease(imgA);
        CGImageRelease(imgB);
        CGImageRelease(imgC);

        NSLog(@"All master icons and preview tiers successfully rendered.");
    }
    return 0;
}
