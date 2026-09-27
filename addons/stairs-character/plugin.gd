@tool
extends EditorPlugin

# Deliberately empty.
#
# Everything this addon provides is the `StairsBody` class, and the engine
# registers it through its .gdextension as soon as the files are in the project -
# enabling a plugin has nothing to do with it. So the addon works whether or not
# this is switched on, and switching it off does not remove the node type.
#
# It exists so the addon appears in Project Settings > Plugins with a name, a
# version and an author, which is how users expect to find and identify what they
# have installed, and it is what the Asset Library lists against. plugin.cfg
# requires a script, and that script must extend EditorPlugin, so here it is.
#
# If this ever grows a body - a custom inspector, a gizmo for step_height, an
# import hook - remember that the class registration still is not its job.
