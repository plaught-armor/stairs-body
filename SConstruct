#!/usr/bin/env python
# Builds StairsBody, the GDExtension in src/.
#
#     scons target=template_debug     # the editor and debug exports load this one
#     scons target=template_release
#
# api_version pins the Godot API the extension is built against; it loads on that
# version and newer.

api_version = "4.6"
env = SConscript("extern/godot-cpp/SConstruct", exports=["api_version"])

env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

# Class reference shown in the editor's help; release templates carry no docs.
if env["target"] in ["editor", "template_debug"]:
    sources.append(env.GodotCPPDocData("src/gen/doc_data.gen.cpp", source=Glob("doc_classes/*.xml")))

library = env.SharedLibrary(
    "addons/stairs-body/bin/libstairsbody{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

env.NoCache(library)
Default(library)
