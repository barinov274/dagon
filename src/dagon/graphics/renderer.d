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

import dlib.core.memory;

import dagon.core.libs;
import dagon.core.ownership;
import dagon.core.event;
import dagon.graphics.gbuffer;
import dagon.graphics.framebuffer;
import dagon.graphics.deferred;
import dagon.graphics.shadow;
import dagon.graphics.rc;
import dagon.graphics.probe;
import dagon.resource.scene;

class Renderer: Owner
{
    Scene scene;
    EventManager eventManager;
    
    GBuffer gbuffer;
    Framebuffer sceneFramebuffer;

    DeferredEnvironmentPass deferredEnvPass;
    DeferredLightPass deferredLightPass;

    CascadedShadowMap shadowMap;

    this(Scene scene, Owner o)
    {
        super(o);
        
        this.scene = scene;
        this.eventManager = scene.eventManager;
        
        gbuffer = New!GBuffer(eventManager.windowWidth, eventManager.windowHeight, this);
        sceneFramebuffer = New!Framebuffer(gbuffer, eventManager.windowWidth, eventManager.windowHeight, true, true, this);
        shadowMap = New!CascadedShadowMap(1024, 10, 30, 200, -100, 100, this);

        deferredEnvPass = New!DeferredEnvironmentPass(gbuffer, sceneFramebuffer, shadowMap, this);
        deferredLightPass = New!DeferredLightPass(gbuffer, this);
    }

    void render(RenderingContext *rc)
    {
    /*
        shadowMap.render(scene, rc);
        gbuffer.render(scene, rc);
        
        sceneFramebuffer.bind();
        
        RenderingContext rcDeferred;
        rcDeferred.initOrtho(eventManager, scene.environment, eventManager.windowWidth, eventManager.windowHeight, 0.0f, 100.0f);
        prepareViewport(sceneFramebuffer);
        sceneFramebuffer.clearBuffers(scene.environment.backgroundColor);
        
        glBindFramebuffer(GL_READ_FRAMEBUFFER, gbuffer.fbo);
        glBlitFramebuffer(0, 0, gbuffer.width, gbuffer.height, 0, 0, gbuffer.width, gbuffer.height, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
        
        scene.renderBackgroundEntities3D(rc);
        deferredEnvPass.render(&rcDeferred, rc);
        deferredLightPass.render(scene, &rcDeferred, rc);
        scene.renderTransparentEntities3D(rc);
        scene.particleSystem.render(rc);
        
        sceneFramebuffer.unbind();
    */
        renderPreStep(rc);
        renderToTarget(sceneFramebuffer, gbuffer, rc);
    
        sceneFramebuffer.swapColorTextureAttachments();
    }
    
    void renderPreStep(RenderingContext *rc)
    {
        shadowMap.render(scene, rc);
        gbuffer.render(scene, rc);
    }
    
    void renderToTarget(RenderTarget rt, GBuffer gbuf, RenderingContext *rc)
    {
        rt.bind();
        
        RenderingContext rcDeferred;
        rcDeferred.initOrtho(eventManager, scene.environment, eventManager.windowWidth, eventManager.windowHeight, 0.0f, 100.0f);
        prepareViewport(rt);
        rt.clear(scene.environment.backgroundColor);
        
        glBindFramebuffer(GL_READ_FRAMEBUFFER, gbuf.fbo);
        glBlitFramebuffer(0, 0, gbuf.width, gbuf.height, 0, 0, gbuf.width, gbuf.height, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
        
        scene.renderBackgroundEntities3D(rc);
        deferredEnvPass.render(&rcDeferred, rc);
        deferredLightPass.render(scene, &rcDeferred, rc);
        scene.renderTransparentEntities3D(rc);
        scene.particleSystem.render(rc);
        
        rt.unbind();
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
}
