﻿/*
Copyright (c) 2018-2020 Timur Gafarov

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

module dagon.graphics.shader;

import core.stdc.string;
import std.stdio;
import std.stdio;
import std.string;
import std.algorithm;
import std.file;

import dlib.core.ownership;
import dlib.core.memory;
import dlib.container.array;
import dlib.container.dict;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.utils: min2;
import dlib.image.color;
import dlib.filesystem.stdfs;
import dlib.text.str;

import dagon.core.bindings;
import dagon.graphics.shaderloader;
import dagon.graphics.texture;
import dagon.graphics.state;

// TODO: move to separate module
class MappedList(T): Owner
{
    Array!T data;
    Dict!(size_t, string) indices;

    this(Owner o)
    {
        super(o);
        indices = New!(Dict!(size_t, string))();
    }

    void set(string name, T val)
    {
        data.append(val);
        indices[name] = data.length - 1;
    }

    T get(string name)
    {
        return data[indices[name]];
    }

    ~this()
    {
        data.free();
        Delete(indices);
    }
}

/**
   A shader program class that can be shared between multiple Shaders.
 */
class ShaderProgram: Owner
{
    immutable GLuint program;

    this(string vertexShaderSrc, string fragmentShaderSrc, Owner o)
    {
        super(o);

        GLuint vert = compileShader(vertexShaderSrc, ShaderStage.vertex);
        GLuint frag = compileShader(fragmentShaderSrc, ShaderStage.fragment);
        if (vert != 0 && frag != 0)
            program = linkShaders(vert, frag);
    }

    void bind()
    {
        glUseProgram(program);
    }

    void unbind()
    {
        glUseProgram(0);
    }
}

/**
   A shader class that wraps OpenGL shader creation and uniform initialization.
 */
abstract class BaseShaderParameter: Owner
{
    Shader shader;
    string name;
    GLint location;
    bool autoBind = true;

    this(Shader shader, string name)
    {
        super(shader);
        this.shader = shader;
        this.name = name;
    }

    void initUniform();
    void bind();
    void unbind();
}

enum ShaderType
{
    Vertex,
    Fragment
}

class ShaderSubroutine: BaseShaderParameter
{
    ShaderType shaderType;
    GLint location;
    GLuint index;
    string subroutineName;

    this(Shader shader, ShaderType shaderType, string name, string subroutineName)
    {
        super(shader, name);
        this.shaderType = shaderType;
        this.subroutineName = subroutineName;
        initUniform();
    }

    override void initUniform()
    {
        if (shaderType == ShaderType.Vertex)
        {
            location = glGetSubroutineUniformLocation(shader.program.program, GL_VERTEX_SHADER, toStringz(name));
            index = glGetSubroutineIndex(shader.program.program, GL_VERTEX_SHADER, toStringz(subroutineName));
        }
        else if (shaderType == ShaderType.Fragment)
        {
            location = glGetSubroutineUniformLocation(shader.program.program, GL_FRAGMENT_SHADER, toStringz(name));
            index = glGetSubroutineIndex(shader.program.program, GL_FRAGMENT_SHADER, toStringz(subroutineName));
        }
    }

    override void bind()
    {
        if (shaderType == ShaderType.Vertex)
        {
            if (location != -1)
                shader.vertexSubroutineIndices[location] = index;
        }
        else if (shaderType == ShaderType.Fragment)
        {
            if (location != -1)
                shader.fragmentSubroutineIndices[location] = index;
        }
    }

    override void unbind()
    {
    }
}

class ShaderParameter(T): BaseShaderParameter
if (is(T == bool) ||
    is(T == int) ||
    is(T == float) ||
    is(T == Vector2f) ||
    is(T == Vector3f) ||
    is(T == Vector4f) ||
    is(T == Color4f) ||
    is(T == Matrix4x4f))
{
    T* source;
    T value;
    T delegate() callback;

    this(Shader shader, string name, T* source)
    {
        super(shader, name);
        this.source = source;
        this.callback = null;
        initUniform();
    }

    this(Shader shader, string name, T value)
    {
        super(shader, name);
        this.source = null;
        this.value = value;
        this.callback = null;
        initUniform();
    }

    this(Shader shader, string name, T delegate() callback)
    {
        super(shader, name);
        this.source = null;
        this.value = value;
        this.callback = callback;
        initUniform();
    }

    override void initUniform()
    {
        location = glGetUniformLocation(shader.program.program, toStringz(name));
    }

    override void bind()
    {
        if (callback)
            value = callback();
        else if (source)
            value = *source;

        static if (is(T == bool) || is(T == int))
        {
            glUniform1i(location, value);
        }
        else static if (is(T == float))
        {
            glUniform1f(location, value);
        }
        else static if (is(T == Vector2f))
        {
            glUniform2fv(location, 1, value.arrayof.ptr);
        }
        else static if (is(T == Vector3f))
        {
            glUniform3fv(location, 1, value.arrayof.ptr);
        }
        else static if (is(T == Vector4f))
        {
            glUniform4fv(location, 1, value.arrayof.ptr);
        }
        else static if (is(T == Color4f))
        {
            glUniform4fv(location, 1, value.arrayof.ptr);
        }
        else static if (is(T == Matrix4x4f))
        {
            glUniformMatrix4fv(location, 1, GL_FALSE, value.arrayof.ptr);
        }
    }

    override void unbind()
    {
        //TODO
    }
}

class Shader: Owner
{
    ShaderProgram program;
    MappedList!BaseShaderParameter parameters;
    GLuint[] vertexSubroutineIndices;
    GLuint[] fragmentSubroutineIndices;

    this(ShaderProgram program, Owner o)
    {
        super(o);
        this.program = program;
        this.parameters = New!(MappedList!BaseShaderParameter)(this);
    }

    static String load(string filename)
    {
        auto fs = New!StdFileSystem();
        auto istrm = fs.openForInput(filename);
        string inputText = readText(istrm);
        Delete(istrm);

        string includePath = "data/__internal/shaders/include/";
        String outputText;
        foreach(line; lineSplitter(inputText))
        {
            auto s = line.strip;
            if (s.startsWith("#include"))
            {
                char[64] buf;
                if (sscanf(s.ptr, "#include <%s>", buf.ptr) == 1)
                {
                    string includeFilename = cast(string)buf[0..strlen(buf.ptr)-1];
                    String includeFullPath = includePath;
                    includeFullPath ~= includeFilename;
                    if (exists(includeFullPath))
                    {
                        istrm = fs.openForInput(includeFullPath.toString);
                        string includeText = readText(istrm);
                        Delete(istrm);
                        outputText ~= includeText;
                        outputText ~= "\n";
                        Delete(includeText);
                    }
                    includeFullPath.free();
                }
                else
                {
                    writeln("Error");
                    break;
                }
            }
            else
            {
                outputText ~= line;
                outputText ~= "\n";
            }
        }

        Delete(fs);
        Delete(inputText);

        return outputText;
    }

    ShaderSubroutine setParameterSubroutine(string name, ShaderType shaderType, string subroutineName)
    {
        if (name in parameters.indices)
        {
            auto sp = cast(ShaderSubroutine)parameters.get(name);
            if (sp is null)
            {
                writefln("Warning: type mismatch for shader parameter \"%s\"", name);
                return null;
            }
            sp.shaderType = shaderType;
            sp.subroutineName = subroutineName;
            sp.initUniform();
            return sp;
        }
        else
        {
            auto sp = New!ShaderSubroutine(this, shaderType, name, subroutineName);
            parameters.set(name, sp);
            return sp;
        }
    }

    ShaderParameter!T setParameter(T)(string name, T val)
    {
        if (name in parameters.indices)
        {
            auto sp = cast(ShaderParameter!T)parameters.get(name);
            if (sp is null)
            {
                writefln("Warning: type mismatch for shader parameter \"%s\"", name);
                return null;
            }

            sp.value = val;
            sp.source = null;
            return sp;
        }
        else
        {
            auto sp = New!(ShaderParameter!T)(this, name, val);
            parameters.set(name, sp);
            return sp;
        }
    }

    ShaderParameter!T setParameterRef(T)(string name, ref T val)
    {
        if (name in parameters.indices)
        {
            auto sp = cast(ShaderParameter!T)parameters.get(name);
            if (sp is null)
            {
                writefln("Warning: type mismatch for shader parameter \"%s\"", name);
                return null;
            }

            sp.source = &val;
            return sp;
        }
        else
        {
            auto sp = New!(ShaderParameter!T)(this, name, &val);
            parameters.set(name, sp);
            return sp;
        }
    }

    ShaderParameter!T setParameterCallback(T)(string name, T delegate() val)
    {
        if (name in parameters.indices)
        {
            auto sp = cast(ShaderParameter!T)parameters.get(name);
            if (sp is null)
            {
                writefln("Warning: type mismatch for shader parameter \"%s\"", name);
                return null;
            }

            sp.callback = val;
            return sp;
        }
        else
        {
            auto sp = New!(ShaderParameter!T)(this, name, val);
            parameters.set(name, sp);
            return sp;
        }
    }

    BaseShaderParameter getParameter(string name)
    {
        if (name in parameters.indices)
        {
            return parameters.get(name);
        }
        else
        {
            writefln("Warning: unknown shader parameter \"%s\"", name);
            return null;
        }
    }

    T getParameterValue(T)(string name)
    {
        if (name in parameters.indices)
        {
            auto sp = cast(ShaderParameter!T)parameters.get(name);
            if (sp is null)
            {
                writefln("Warning: type mismatch for shader parameter \"%s\"", name);
                return T.init;
            }

            if (sp.source)
                return *sp.source;
            else
                return sp.value;
        }
        else
        {
            writefln("Warning: unknown shader parameter \"%s\"", name);
            return T.init;
        }
    }

    void bind()
    {
        program.bind();
    }

    void unbind()
    {
        program.unbind();
    }

    void bindParameters(GraphicsState* state)
    {
        GLsizei n;
        glGetProgramStageiv(program.program, GL_VERTEX_SHADER, GL_ACTIVE_SUBROUTINE_UNIFORM_LOCATIONS, &n);
        if (n > 0 && n != vertexSubroutineIndices.length)
            vertexSubroutineIndices = New!(GLuint[])(n);

        glGetProgramStageiv(program.program, GL_FRAGMENT_SHADER, GL_ACTIVE_SUBROUTINE_UNIFORM_LOCATIONS, &n);
        if (n > 0 && n != fragmentSubroutineIndices.length)
            fragmentSubroutineIndices = New!(GLuint[])(n);

        foreach(v; parameters.data)
        {
            if (v.autoBind)
                v.bind();
        }

        if (vertexSubroutineIndices.length)
            glUniformSubroutinesuiv(GL_VERTEX_SHADER, cast(uint)vertexSubroutineIndices.length, vertexSubroutineIndices.ptr);

        if (fragmentSubroutineIndices.length)
            glUniformSubroutinesuiv(GL_FRAGMENT_SHADER, cast(uint)fragmentSubroutineIndices.length, fragmentSubroutineIndices.ptr);
        
        debug validate();
    }

    void unbindParameters(GraphicsState* state)
    {
        foreach(v; parameters.data)
        {
            if (v.autoBind)
                v.unbind();
        }
    }

    void validate()
    {
        glValidateProgram(program.program);
        
        GLint status;
        glGetProgramiv(program.program, GL_VALIDATE_STATUS, &status);
        
        GLint infolen;
        glGetProgramiv(program.program, GL_INFO_LOG_LENGTH, &infolen);
        if (infolen > 0)
        {
            char[logMaxLen + 1] infobuffer = 0;
            glGetProgramInfoLog(program.program, logMaxLen, null, infobuffer.ptr);
            infolen = min2(infolen - 1, logMaxLen);
            char[] s = stripRight(infobuffer[0..infolen]);
            writeln(s);
        }
        
        assert(status == GL_TRUE, "Shader program validation failed");
    }
    
    ~this()
    {
        if (vertexSubroutineIndices.length)
            Delete(vertexSubroutineIndices);
        if (fragmentSubroutineIndices.length)
            Delete(fragmentSubroutineIndices);
    }
}
