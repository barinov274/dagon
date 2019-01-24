/*
Copyright (c) 2018 Timur Gafarov

Boost Software License - Version 1.0 - August 17th, 2003
Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dagon.graphics.renderer;

import std.stdio;
import std.math;
import std.algorithm;
import std.traits;

import dlib.core.memory;
import dlib.container.array;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;

import dagon.core.libs;
import dagon.core.ownership;
import dagon.core.event;
import dagon.graphics.gbuffer;
import dagon.graphics.framebuffer;
import dagon.graphics.deferred;
import dagon.graphics.shadow;
import dagon.graphics.view;
import dagon.graphics.rc;
import dagon.graphics.postproc;
import dagon.graphics.texture;
import dagon.graphics.cubemap;
import dagon.graphics.cubemaprendertarget;
import dagon.resource.scene;

import dagon.graphics.filters.fxaa;
import dagon.graphics.filters.lens;
import dagon.graphics.filters.hdrprepass;
import dagon.graphics.filters.hdr;
import dagon.graphics.filters.blur;
import dagon.graphics.filters.finalizer;

import dagon.graphics.shader;
import dagon.logics.entity;

class DecalShader: Shader
{
    string vs = "
#version 400 core

uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;

layout (location = 0) in vec3 va_Vertex;

void main()
{
    gl_Position = projectionMatrix * modelViewMatrix * vec4(va_Vertex, 1.0);
}
";
    string fs = "
#version 400 core

uniform sampler2D positionBuffer;

uniform vec2 viewSize;

uniform mat4 invViewMatrix;
uniform mat4 invModelMatrix;

vec3 toLinear(vec3 v)
{
    return pow(v, vec3(2.2));
}

layout(location = 0) out vec4 frag_color;

void main()
{
    vec2 texCoord = gl_FragCoord.xy / viewSize;

    vec3 eyePos = texture(positionBuffer, texCoord).xyz;

    vec3 worldPos = (invViewMatrix * vec4(eyePos, 1.0)).xyz;
    vec3 objPos = (invModelMatrix * vec4(worldPos, 1.0)).xyz;

    // Perform bounds check to discard fragments outside the decal box
    vec3 c = vec3(0.0, 1.0, 0.0);
    if (abs(objPos.x) > 1.0) c = vec3(1.0, 0.0, 0.0);
    if (abs(objPos.y) > 1.0) c = vec3(1.0, 0.0, 0.0);
    if (abs(objPos.z) > 1.0) c = vec3(1.0, 0.0, 0.0);

    vec3 color = toLinear(c);

    frag_color = vec4(color, 1.0);
}
";
    GBuffer gbuffer;

    this(GBuffer gbuffer, Owner o)
    {
        auto myProgram = New!ShaderProgram(vs, fs, this);
        super(myProgram, o);
        this.gbuffer = gbuffer;
    }

    override void bind(RenderingContext* rc)
    {
        setParameter("modelViewMatrix", rc.modelViewMatrix);
        setParameter("projectionMatrix", rc.projectionMatrix);
        setParameter("invViewMatrix", rc.invViewMatrix);
        setParameter("invModelMatrix", rc.invModelMatrix);
        setParameter("viewSize", Vector2f(gbuffer.width, gbuffer.height));

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, gbuffer.positionTexture);
        setParameter("positionTexture", 0);

        super.bind(rc);
    }

    override void unbind(RenderingContext* rc)
    {
        super.unbind(rc);

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, 0);
    }
}

class Renderer: Owner
{
    Scene scene;
    EventManager eventManager;

    GBuffer gbuffer;
    Framebuffer sceneFramebuffer;

    DeferredEnvironmentPass deferredEnvPass;
    DeferredLightPass deferredLightPass;

    DynamicArray!PostFilter postFilters;

    PostFilterHDR hdrFilter;

    Framebuffer hdrPrepassFramebuffer;
    PostFilterHDRPrepass hdrPrepassFilter;

    Framebuffer hblurredFramebuffer;
    Framebuffer vblurredFramebuffer;
    PostFilterBlur hblur;
    PostFilterBlur vblur;

    PostFilterFXAA fxaaFilter;
    PostFilterLensDistortion lensFilter;

    PostFilterFinalizer finalizerFilter;

    SSAOSettings ssao;
    HDRSettings hdr;
    MotionBlurSettings motionBlur;
    GlowSettings glow;
    LUTSettings lut;
    VignetteSettings vignette;
    AASettings antiAliasing;
    LensSettings lensDistortion;

    RenderingContext rc3d;
    RenderingContext rc2d;

    GLuint decalFbo;

    this(Scene scene, Owner o)
    {
        super(o);

        this.scene = scene;
        this.eventManager = scene.eventManager;

        gbuffer = New!GBuffer(eventManager.windowWidth, eventManager.windowHeight, this);
        sceneFramebuffer = New!Framebuffer(gbuffer, eventManager.windowWidth, eventManager.windowHeight, true, true, this);

        deferredEnvPass = New!DeferredEnvironmentPass(gbuffer, this);
        deferredLightPass = New!DeferredLightPass(gbuffer, this);

        ssao.renderer = this;
        hdr.renderer = this;
        motionBlur.renderer = this;
        glow.renderer = this;
        glow.radius = 7;
        lut.renderer = this;
        vignette.renderer = this;
        antiAliasing.renderer = this;
        lensDistortion.renderer = this;

        hblurredFramebuffer = New!Framebuffer(gbuffer, eventManager.windowWidth / 2, eventManager.windowHeight / 2, true, false, this);
        hblur = New!PostFilterBlur(true, sceneFramebuffer, hblurredFramebuffer, this);

        vblurredFramebuffer = New!Framebuffer(gbuffer, eventManager.windowWidth / 2, eventManager.windowHeight / 2, true, false, this);
        vblur = New!PostFilterBlur(false, hblurredFramebuffer, vblurredFramebuffer, this);

        hdrPrepassFramebuffer = New!Framebuffer(gbuffer, eventManager.windowWidth, eventManager.windowHeight, true, false, this);
        hdrPrepassFilter = New!PostFilterHDRPrepass(sceneFramebuffer, hdrPrepassFramebuffer, this);
        hdrPrepassFilter.blurredTexture = vblurredFramebuffer.currentColorTexture;
        postFilters.append(hdrPrepassFilter);

        hdrFilter = New!PostFilterHDR(hdrPrepassFramebuffer, null, this);
        hdrFilter.velocityTexture = gbuffer.velocityTexture;
        postFilters.append(hdrFilter);

        fxaaFilter = New!PostFilterFXAA(null, null, this);
        postFilters.append(fxaaFilter);
        fxaaFilter.enabled = false;

        lensFilter = New!PostFilterLensDistortion(null, null, this);
        postFilters.append(lensFilter);
        lensFilter.enabled = false;

        finalizerFilter = New!PostFilterFinalizer(null, null, this);

        rc3d.initPerspective(eventManager, scene.environment, 60.0f, 0.1f, 1000.0f);
        rc2d.initOrtho(eventManager, scene.environment, 0.0f, 100.0f);

        glGenFramebuffers(1, &decalFbo);
        glBindFramebuffer(GL_FRAMEBUFFER, decalFbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gbuffer.colorTexture, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, gbuffer.depthTexture, 0);

        GLenum[1] bufs = [GL_COLOR_ATTACHMENT0];
        glDrawBuffers(1, bufs.ptr);

        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE)
            writeln(status);

        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    ~this()
    {
        postFilters.free();

        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &decalFbo);
    }

    PostFilter addFilter(PostFilter f)
    {
        postFilters.append(f);
        return f;
    }

    void renderToCubemap(Vector3f position, Cubemap cubemap)
    {
        if (scene.environment.environmentMap is cubemap)
        {
            writeln("Warning: feedback loop detected in renderToCubemap");
            return;
        }

        CubemapRenderTarget rt = New!CubemapRenderTarget(cubemap.width, null);
        renderToCubemap(position, cubemap, rt);
        Delete(rt);
    }

    void renderToCubemap(Vector3f position, Cubemap cubemap, CubemapRenderTarget rt)
    {
        if (scene.environment.environmentMap is cubemap)
        {
            writeln("Warning: feedback loop detected in renderToCubemap");
            return;
        }

        scene.fixedStepUpdate(false);

        RenderingContext rcCubemap;
        rcCubemap.init(eventManager, scene.environment);
        rcCubemap.projectionMatrix = perspectiveMatrix(90.0f, 1.0f, 0.001f, 1000.0f);

        foreach(face; EnumMembers!CubeFace)
        {
            rt.prepareRC(face, position, &rcCubemap);
            rt.setCubemapFace(cubemap, face);
            //TODO: simplified shadow rendering (lower resolution, only one cascade, render only once per cubemap)
            scene.lightManager.updateShadows(position, Vector3f(0.0f, 0.0f, 1.0f), &rcCubemap, scene.fixedTimeStep);
            renderPreStep(rt.gbuffer, &rcCubemap);
            renderToTarget(rt, rt.gbuffer, &rcCubemap);
        }

        cubemap.invalidateMipmap();
    }

    void render()
    {
        RenderingContext *rc = &rc3d;

        renderPreStep(gbuffer, rc);
        renderToTarget(sceneFramebuffer, gbuffer, rc);
        sceneFramebuffer.swapColorTextureAttachments();

        if (hdrFilter.autoExposure)
        {
            sceneFramebuffer.genLuminanceMipmaps();
            float lum = sceneFramebuffer.averageLuminance();

            if (!isNaN(lum))
            {
                float newExposure = hdrFilter.keyValue * (1.0f / clamp(lum, hdrFilter.minLuminance, hdrFilter.maxLuminance));

                float exposureDelta = newExposure - hdrFilter.exposure;
                hdrFilter.exposure += exposureDelta * hdrFilter.adaptationSpeed * eventManager.deltaTime;
            }
        }

        if (hdrPrepassFilter.glowEnabled)
            renderBlur(glow.radius);

        RenderingContext rcTmp;
        Framebuffer nextInput = sceneFramebuffer;

        hdrPrepassFilter.perspectiveMatrix = rc.projectionMatrix;

        foreach(i, f; postFilters.data)
        if (f.enabled)
        {
            if (f.outputBuffer is null)
                f.outputBuffer = New!Framebuffer(gbuffer, eventManager.windowWidth, eventManager.windowHeight, false, false, this);

            if (f.inputBuffer is null)
                f.inputBuffer = nextInput;

            nextInput = f.outputBuffer;

            f.outputBuffer.bind();
            rcTmp.initOrtho(eventManager, scene.environment, f.outputBuffer.width, f.outputBuffer.height, 0.0f, 100.0f);
            prepareViewport(f.outputBuffer);
            f.render(&rcTmp);
            f.outputBuffer.unbind();
        }

        prepareViewport();
        finalizerFilter.inputBuffer = nextInput;
        finalizerFilter.render(&rc2d);

        renderEntities2D(scene, &rc2d);
    }

    void renderPreStep(GBuffer gbuf, RenderingContext *rc)
    {
        scene.lightManager.renderShadows(scene, rc);
        gbuf.render(scene, rc);

        glBindFramebuffer(GL_FRAMEBUFFER, decalFbo);
        glDisable(GL_DEPTH_TEST);
        foreach(e; scene.decals)
            e.render(rc);
        glEnable(GL_DEPTH_TEST);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    void renderToTarget(RenderTarget rt, GBuffer gbuf, RenderingContext *rc)
    {
        rt.bind();

        RenderingContext rcDeferred;
        rcDeferred.initOrtho(eventManager, scene.environment, gbuf.width, gbuf.height, 0.0f, 100.0f);
        prepareViewport(rt);
        rt.clear(scene.environment.backgroundColor);

        glBindFramebuffer(GL_READ_FRAMEBUFFER, gbuf.fbo);
        glBlitFramebuffer(0, 0, gbuf.width, gbuf.height, 0, 0, gbuf.width, gbuf.height, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);

        deferredEnvPass.gbuffer = gbuf;
        deferredLightPass.gbuffer = gbuf;

        renderBackgroundEntities3D(scene, rc);
        deferredEnvPass.render(&rcDeferred, rc);
        deferredLightPass.render(scene, &rcDeferred, rc);
        renderTransparentEntities3D(scene, rc);
        scene.particleSystem.render(rc);

        rt.unbind();
    }

    // TODO: add EntityGroup for this
    void renderBackgroundEntities3D(Scene scene, RenderingContext* rc)
    {
        glEnable(GL_DEPTH_TEST);
        foreach(e; scene.entities3Dflat)
            if (e.layer <= 0)
                e.render(rc);
    }

    // TODO: add EntityGroup for this
    void renderOpaqueEntities3D(Scene scene, RenderingContext* rc)
    {
        glEnable(GL_DEPTH_TEST);
        RenderingContext rcLocal = *rc;
        rcLocal.ignoreTransparentEntities = true;
        foreach(e; scene.entities3Dflat)
        {
            if (e.layer > 0)
                e.render(&rcLocal);
        }
    }

    // TODO: add EntityGroup for this
    void renderTransparentEntities3D(Scene scene, RenderingContext* rc)
    {
        glEnable(GL_DEPTH_TEST);
        RenderingContext rcLocal = *rc;
        rcLocal.ignoreOpaqueEntities = true;
        foreach(e; scene.entities3Dflat)
        {
            if (e.layer > 0)
                e.render(&rcLocal);
        }
    }

    void renderEntities3D(Scene scene, RenderingContext* rc)
    {
        glEnable(GL_DEPTH_TEST);
        foreach(e; scene.entities3Dflat)
            e.render(rc);
    }

    void renderEntities2D(Scene scene, RenderingContext* rc)
    {
        glDisable(GL_DEPTH_TEST);
        foreach(e; scene.entities2Dflat)
            e.render(rc);
    }

    void prepareViewport(RenderTarget rt = null)
    {
        glEnable(GL_SCISSOR_TEST);
        if (rt)
        {
            glScissor(0, 0, rt.width, rt.height);
            glViewport(0, 0, rt.width, rt.height);
        }
        else
        {
            glScissor(0, 0, eventManager.windowWidth, eventManager.windowHeight);
            glViewport(0, 0, eventManager.windowWidth, eventManager.windowHeight);
        }
        glClearColor(
            scene.environment.backgroundColor.r,
            scene.environment.backgroundColor.g,
            scene.environment.backgroundColor.b, 0.0f);
    }

    void renderBlur(uint iterations)
    {
        RenderingContext rcTmp;

        foreach(i; 1..iterations+1)
        {
            hblur.outputBuffer.bind();
            rcTmp.initOrtho(eventManager, scene.environment, hblur.outputBuffer.width, hblur.outputBuffer.height, 0.0f, 100.0f);
            prepareViewport(hblur.outputBuffer);
            hblur.radius = i;
            hblur.render(&rcTmp);
            hblur.outputBuffer.unbind();

            vblur.outputBuffer.bind();
            rcTmp.initOrtho(eventManager, scene.environment, vblur.outputBuffer.width, vblur.outputBuffer.height, 0.0f, 100.0f);
            prepareViewport(vblur.outputBuffer);
            vblur.radius = i;
            vblur.render(&rcTmp);
            vblur.outputBuffer.unbind();

            hblur.inputBuffer = vblur.outputBuffer;
        }

        hblur.inputBuffer = sceneFramebuffer;
    }
}

struct SSAOSettings
{
    Renderer renderer;
    void enabled(bool mode) @property { renderer.deferredEnvPass.shader.enableSSAO = mode; }
    bool enabled() @property { return renderer.deferredEnvPass.shader.enableSSAO; }
    void samples(int s) @property { renderer.deferredEnvPass.shader.ssaoSamples = s; }
    int samples() @property { return renderer.deferredEnvPass.shader.ssaoSamples; }
    void radius(float r) @property { renderer.deferredEnvPass.shader.ssaoRadius = r; }
    float radius() @property { return renderer.deferredEnvPass.shader.ssaoRadius; }
    void power(float p) @property { renderer.deferredEnvPass.shader.ssaoPower = p; }
    float power() @property { return renderer.deferredEnvPass.shader.ssaoPower; }
}

struct HDRSettings
{
    Renderer renderer;
    void tonemapper(Tonemapper f) @property { renderer.hdrFilter.tonemapFunction = f; }
    Tonemapper tonemapper() @property { return renderer.hdrFilter.tonemapFunction; }
    void exposure(float ex) @property { renderer.hdrFilter.exposure = ex; }
    float exposure() @property { return renderer.hdrFilter.exposure; }
    void autoExposure(bool mode) @property { renderer.hdrFilter.autoExposure = mode; }
    bool autoExposure() @property { return renderer.hdrFilter.autoExposure; }
    void minLuminance(float l) @property { renderer.hdrFilter.minLuminance = l; }
    float minLuminance() @property { return renderer.hdrFilter.minLuminance; }
    void maxLuminance(float l) @property { renderer.hdrFilter.maxLuminance = l; }
    float maxLuminance() @property { return renderer.hdrFilter.maxLuminance; }
    void keyValue(float k) @property { renderer.hdrFilter.keyValue = k; }
    float keyValue() @property { return renderer.hdrFilter.keyValue; }
    void adaptationSpeed(float s) @property { renderer.hdrFilter.adaptationSpeed = s; }
    float adaptationSpeed() @property { return renderer.hdrFilter.adaptationSpeed; }
    void linearity(float l) @property { renderer.hdrFilter.parametricTonemapperLinearity = l; }
    float linearity() @property { return renderer.hdrFilter.parametricTonemapperLinearity; }
}

struct GlowSettings
{
    Renderer renderer;
    uint radius;
    void enabled(bool mode) @property
    {
        renderer.hblur.enabled = mode;
        renderer.vblur.enabled = mode;
        renderer.hdrPrepassFilter.glowEnabled = mode;
    }
    bool enabled() @property { return renderer.hdrPrepassFilter.glowEnabled; }
    void brightness(float b) @property { renderer.hdrPrepassFilter.glowBrightness = b; }
    float brightness() @property { return renderer.hdrPrepassFilter.glowBrightness; }
    void minLuminanceThreshold(float t) @property { renderer.hdrPrepassFilter.glowMinLuminanceThreshold = t; }
    float minLuminanceThreshold() @property { return renderer.hdrPrepassFilter.glowMinLuminanceThreshold; }
    void maxLuminanceThreshold(float t) @property { renderer.hdrPrepassFilter.glowMaxLuminanceThreshold = t; }
    float maxLuminanceThreshold() @property { return renderer.hdrPrepassFilter.glowMaxLuminanceThreshold; }
}

struct MotionBlurSettings
{
    Renderer renderer;
    void enabled(bool mode) @property { renderer.hdrFilter.mblurEnabled = mode; }
    bool enabled() @property { return renderer.hdrFilter.mblurEnabled; }
    void samples(uint s) @property { renderer.hdrFilter.motionBlurSamples = s; }
    uint samples() @property { return renderer.hdrFilter.motionBlurSamples; }
    void shutterSpeed(float s) @property
    {
        renderer.hdrFilter.shutterSpeed = s;
        renderer.hdrFilter.shutterFps = 1.0 / s;
    }
    float shutterSpeed() @property { return renderer.hdrFilter.shutterSpeed; }
}

struct LUTSettings
{
    Renderer renderer;
    void texture(Texture tex) @property { renderer.hdrFilter.colorTable = tex; }
    Texture texture() @property { return renderer.hdrFilter.colorTable; }
}

struct VignetteSettings
{
    Renderer renderer;
    void texture(Texture tex) @property { renderer.hdrFilter.vignette = tex; }
    Texture texture() @property { return renderer.hdrFilter.vignette; }
}

struct AASettings
{
    Renderer renderer;
    void enabled(bool mode) @property { renderer.fxaaFilter.enabled = mode; }
    bool enabled() @property { return renderer.fxaaFilter.enabled; }
}

struct LensSettings
{
    Renderer renderer;
    void enabled(bool mode) @property { renderer.lensFilter.enabled = mode; }
    bool enabled() @property { return renderer.lensFilter.enabled; }
    void scale(float s) @property { renderer.lensFilter.scale = s; }
    float scale() @property { return renderer.lensFilter.scale; }
    void dispersion(float d) @property { renderer.lensFilter.dispersion = d; }
    float dispersion() @property { return renderer.lensFilter.dispersion; }
}
