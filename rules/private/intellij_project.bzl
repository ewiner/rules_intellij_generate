load(":intellij_module.bzl", "IntellijModuleConfig")

BazelPackageDep = provider(
    fields = {
        "bazel_package": "package name",
        "label_name": "label name",
        "attr_name": "the attribute name through which the dependency was established",
        "depends_on_bazel_package": "the bazel package depends on this other package",
    }
)

BazelPackageDeps = provider(
    fields = {
        "all": "all bazel package dependencies",
    }
)

JarDep = provider(
    fields = {
        "bazel_package": "package name of the target",
        "label_name": "label name of the target that generated this jar",
        "generated_by_build": "is this file generated by the build, or already-existing?",
        "relative_jar_path": "the path to the jar from the execroot",
        "owner_workspace_root": "the workspace root of the owner of the jar",
    }
)

JarDeps = provider(
    fields = {
        "all": "all jars for module",
    }
)

DeclaredIntellijModule = provider(
    fields = {
        "bazel_package": "the bazel package that this module represents",
        "module_name_override": "intellij module name, must be unique across the project",
        "iml_type": "the type of iml file to use, defined in the iml_types xml file",
    }
)

ProjectData = provider(
    fields = [
        "bazel_package_deps",
        "build_managed_label_matchlist",
        "iml_types_path",
        "jar_deps",
        "module_dependency_matchlist",
        "modules",
        "project_root_files_paths",
        "project_root_files_path_ignore_prefix",
        "root_bazel_package",
        "symlinks",
        "test_lib_label_matchlist",
        "workspace_xml_fragment_paths",
    ]
)

def _target_attrs_from_struct(a_struct):
    """Returns the attrs of a_struct that have a list of Targets"""
    attr_name_to_targets = {}

    for attr_candidate_name in dir(a_struct):

        if attr_candidate_name == "to_json" or attr_candidate_name == "to_proto":
            continue

        attr_candidate = getattr(a_struct, attr_candidate_name)

        # TODO: also should work for single-target attrs - scenario test for this (custom attrs...)
        if type(attr_candidate) == "list" and len(attr_candidate) > 0 and type(attr_candidate[0]) == "Target":
            attr_name_to_targets[attr_candidate_name] = attr_candidate

    return attr_name_to_targets

def _gather_bazel_package_dependencies(target, ctx):
    """Recurse through target dependencies, and accumulate all package-to-package dependencies.

    A bazel package dependency, for the purposes of this rules project, is established when a target in
    one package relates to a target in another package, via a target attribute that contains a reference
    to a label in the other package."""
    all_bazel_package_dependencies = {}

    attr_name_to_targets = _target_attrs_from_struct(ctx.rule.attr)
    for attr_name in attr_name_to_targets:
        for d in attr_name_to_targets[attr_name]:
            if BazelPackageDeps in d:
                all_bazel_package_dependencies.update(d[BazelPackageDeps].all)

            if target.label.workspace_root == "" and \
                d.label.workspace_root == "" and \
                target.label.package != d.label.package:

                # make sure we only ever have one copy of this we pass through in the json.
                key = "%s;%s;%s;%s" % (target.label.package, target.label.name, attr_name, d.label.package)

                if key not in all_bazel_package_dependencies:
                    all_bazel_package_dependencies[key] = \
                        BazelPackageDep(
                            bazel_package=target.label.package,
                            label_name=target.label.name,
                            attr_name=attr_name,
                            depends_on_bazel_package=d.label.package)

    return [BazelPackageDeps(all=all_bazel_package_dependencies)]

_gather_bazel_package_dependencies_aspect = aspect(
    implementation = _gather_bazel_package_dependencies,
    attr_aspects = ["*"],
)

def _declared_modules(ctx):
    """All modules 'declared' in the project, i.e. per intellij_module target."""

    all_modules = []
    for intellij_module in ctx.attr.modules:
        all_modules.append(
            DeclaredIntellijModule(
                bazel_package=intellij_module.label.package,
                module_name_override=intellij_module[IntellijModuleConfig].module_name_override,
                iml_type=intellij_module[IntellijModuleConfig].iml_type))
    return all_modules

def _jar_dep(labeled, jar):
    return JarDep(
        bazel_package=labeled.label.package,
        label_name=labeled.label.name,

        # is_source means "Returns true if this is a source file, i.e. it is not generated."
        # We use this to distinguish between build-generated jars, and "external" jars

        generated_by_build=not jar.is_source,
        relative_jar_path=jar.path,
        owner_workspace_root=jar.owner.workspace_root)

def _jar_dep_key(j):
    # make sure we only ever have one copy of this we pass through in the json.
    return "%s;%s;%s;%s;%s" % (j.bazel_package, j.label_name, j.relative_jar_path, j.generated_by_build, j.owner_workspace_root)

def _jar_deps(target, ctx):
    """Walk all dependencies and gather up associations between bazel packages and jars."""

    # We must use transitive_runtime_jars, to get at the full jars, at the moment
    # see https://stackoverflow.com/a/45942563

    all_jar_deps = {}

    if JavaInfo in target:
        for jar in target[JavaInfo].transitive_runtime_jars.to_list():
            j = _jar_dep(target, jar)
            key = _jar_dep_key(j)
            all_jar_deps[key] = j
    if JarDeps in target:
        all_jar_deps.update(target[JarDeps].all)

    attr_name_to_targets = _target_attrs_from_struct(ctx.rule.attr)
    for attr_name in attr_name_to_targets:
        for d in attr_name_to_targets[attr_name]:
            if JarDeps in d:
                all_jar_deps.update(d[JarDeps].all)
            if JavaInfo in d:
                for jar in d[JavaInfo].transitive_runtime_jars.to_list():
                    j = _jar_dep(target, jar)
                    key = _jar_dep_key(j)
                    all_jar_deps[key] = j

    return [JarDeps(all=all_jar_deps)]

_gather_jar_deps_aspect = aspect(
    implementation = _jar_deps,
    attr_aspects = ["*"],
)

def _all_jar_deps(ctx):
    all_jar_deps = {}

    for dep in ctx.attr.deps:
        all_jar_deps.update(dep[JarDeps].all)

    keys_sorted = sorted(all_jar_deps.keys())
    results = []
    for k in keys_sorted:
        results.append(all_jar_deps[k])
    return results

def _bazel_package_deps(ctx):
    all_deps = {}
    for dep in ctx.attr.deps:
        all_deps.update(dep[BazelPackageDeps].all)
    keys_sorted = sorted(all_deps.keys())
    results = []
    for k in keys_sorted:
        results.append(all_deps[k])
    return results

def _impl(ctx):
    """Main rule method"""
    project_data_json_file = ctx.actions.declare_file("project-data.json")
    iml_types_file = ctx.attr.iml_types_file.files.to_list()[0]

    inputs = [
       iml_types_file,
       project_data_json_file,
    ]

    # gather up all top-level project files - the xml files that will go under the .idea directory
    paths = []
    if hasattr(ctx.attr.project_root_filegroup, "files"):
        inputs.extend(ctx.attr.project_root_filegroup.files.to_list())
        for f in ctx.attr.project_root_filegroup.files.to_list():
            paths.append(f.path)

    # gather up all workspace fragment files - these will be used as parts of .idea/workspace.xml
    workspace_xml_fragment_paths = []
    if hasattr(ctx.attr.workspace_xml_fragments_filegroup, "files"):
        inputs.extend(ctx.attr.workspace_xml_fragments_filegroup.files.to_list())
        for f in ctx.attr.workspace_xml_fragments_filegroup.files.to_list():
            workspace_xml_fragment_paths.append(f.path)

    # call out and gather data about this build, traversing build targets to find package dependencies and jars.
    project_data = ProjectData(
        root_bazel_package = ctx.label.package,
        bazel_package_deps = _bazel_package_deps(ctx),
        module_dependency_matchlist = ctx.attr.module_dependency_matchlist,
        jar_deps = _all_jar_deps(ctx),
        build_managed_label_matchlist = ctx.attr.build_managed_label_matchlist,
        test_lib_label_matchlist = ctx.attr.test_lib_label_matchlist,
        iml_types_path = iml_types_file.path,
        modules = _declared_modules(ctx),
        project_root_files_paths = paths,
        project_root_files_path_ignore_prefix = ctx.attr.project_root_filegroup_ignore_prefix,
        workspace_xml_fragment_paths = workspace_xml_fragment_paths,
        symlinks = ctx.attr.symlinks
    )

    # this json file is the "input" to the python transformation executable action
    ctx.actions.write(
        output=project_data_json_file,
        content=project_data.to_json())

    # execute the python script that transforms the input project data,
    # to an archive files containing all "managed" intellij configuration files.
    ctx.actions.run(
        executable = ctx.executable._intellij_generate_project_files,
        arguments = [
            project_data_json_file.path,
            ctx.outputs.intellij_files.path
        ],
        inputs = inputs,
        outputs = [ctx.outputs.intellij_files],
        progress_message = "Generating intellij project files: %s" % ctx.outputs.intellij_files.path)

    # build up a list of custom substitution variables that the install script will
    # use to transform the (templated) files into the intellij archive into
    # final intellij config files
    all_substitutions = {}
    all_substitutions.update(ctx.attr.custom_substitutions)

    custom_env_vars_str = ""
    for k in all_substitutions:
        # note: the "tools" attribute magically causes expand_location to see the dependencies specified there
        # see https://stackoverflow.com/a/44025866
        custom_env_vars_str += "'%s':'%s',\n" % (k, ctx.expand_location(all_substitutions[k]))

    if custom_env_vars_str == "":
        custom_env_vars_str = "# (note: no custom substitutions defined)"

    ctx.actions.expand_template(
        output=ctx.outputs.install_intellij_files_script,
        template=ctx.file._install_script_template_file,
        substitutions={
            "# _CUSTOM_ENV_VARS_GO_HERE": custom_env_vars_str
        },
        is_executable=True)

    ctx.actions.expand_template(
        output=ctx.outputs.fswatch_and_install_intellij_files_mac_sh,
        template=ctx.file._fswatch_and_install_intellij_files_mac_template_file,
        substitutions={},
        is_executable=True)


intellij_project = rule(
    implementation = _impl,
    attrs = {
        "_intellij_generate_project_files": attr.label(
            default=Label("//private:intellij_generate_project_files"),
            executable=True,
            cfg="target"),

        "_install_script_template_file": attr.label(
            default=Label("//private:install_intellij_files.py.template"), allow_single_file=True),

        "_fswatch_and_install_intellij_files_mac_template_file": attr.label(
            default=Label("//private:fswatch_and_install_intellij_files_mac.sh.template"), allow_single_file=True),

        "deps": attr.label_list(
            default=[],
            aspects=[_gather_bazel_package_dependencies_aspect, _gather_jar_deps_aspect],
            doc="""
            This is the list of targets that the aspects will walk, to gather information about target
            and jar dependencies.

            So, these targets are what determine what packages are related, and therefore,
            what Intellij modules are related.
            """),

        "module_dependency_matchlist": attr.string_list(
            default=[ # in the attr docs...srcs/data/deps are the three principle types of dependencies
                '{"attr":"data"}',
                '{"attr":"deps"}',
                '{"attr":"srcs"}',
            ], doc="""
            A series of match rules on a source target, one of its attributes names, and a target that it depends on,
            which decides what entries drive the determination of bazel package dependnencies, and therefore,
            intellij module dependencies.

            An entry in the matchlist is a stringified json document of the form:

            {"package":"foo","attr":"deps","to_package":"bar"}

            This example would be very restrictive: only module dependencies flowing from package foo to package bar,
            via an attribute on foo called deps, would impact how the Intellij project is constructed.

            Wildcards are possible:

            {"package":"foo","attr":"deps","to_package":"*"}

            The now means: consider all dependencies found flowing from foo, via attr deps.

            The equivalent shorthand:

            {"package":"foo","attr":"deps"}

            Any ommitted attribute is treated as an implicit * / "match all", so:

            {"attr":"zorg"}

            means all dependencies established from any package, to any other package, via the attribute name "zorg",
            will be used to construct Intellij module dependencies.
            """),

        "build_managed_label_matchlist": attr.string_list(default=[],
                                                      doc="""
                                                      A matcher list of the form

                                                      {"package":"*","label_name":"java_grpc"}

                                                      which determines what jars, that are generated based on code in
                                                      the project, are "bazel-managed" - that is to say, Intellij
                                                      does not attempt any sort of compilation related to these jars.

                                                      The most prominent example is protobuf-codegen. Users need
                                                      the generated code, compiled, and jar'd, to be available in order
                                                      to sensibly develop code based on these proto defintions.

                                                      Assuming all java proto codegen targets are named "java_proto",
                                                      this match rule will cause all proto jars to be included as
                                                      module jar libraries:

                                                      {"label_name":"java_proto"}
                                                      """),

        "test_lib_label_matchlist": attr.string_list(default=[],
                                                 doc="""
                                                     A matcher list of the form

                                                     {"package":"*","label_name":"java_test"}

                                                     which determines what jar libraries are marked as "Test" libraries
                                                     in Intellij modules. Note: any jars that are dependencies of
                                                     non-test targets in the same module/bazel package, will cause
                                                     the jar dependency to be marked as a "Compile" jar library.
                                                     """),

        "custom_substitutions": attr.string_dict(default={},
                                                 doc="""
                                                 Variables that may be used in intellij xml files and templates, which
                                                 are committed into the client project. At intellij project file
                                                 installation time, these variables are substituted for their values,
                                                 specified here.
                                                 """),

        "iml_types_file": attr.label(mandatory=True, allow_single_file=True,
                                     doc = """
                                     A file containing iml type names, and xml contents that form the basis of
                                     intellij module files, for a given iml type.
                                     """),

        "project_root_filegroup": attr.label(default=None,
                                             doc="""
                                             Filegroup of files that will be placed under the .idea directory -
                                             i.e. the intellij project directory.
                                             """),

        "project_root_filegroup_ignore_prefix": attr.string(
            doc="""
            Prefix that should be stripped off the project_root_filegroup files, before they're placed under the .idea
            directory.

            (This is not the most elegant idea, but I can't think of a better approach for accomplishing this goal,
            at the moment)
            """),

        "workspace_xml_fragments_filegroup": attr.label(default=None,
                                                        doc="""
                                                        A filegroup of xml files that should each correspond to
                                                        a workspace.xml "component". These should be named with
                                                        the component name in the middle of the filename, ex:

                                                        workspace.RunManager.xml

                                                        The installer will overwrite any components with these names.

                                                        This way, it's possible to control the contents of (only) parts
                                                        of workspace.xml, and let other parts be managed directly by
                                                        Intellij.
                                                        """),
        "modules": attr.label_list(default=[],
                                   doc="""
                                   intellij_module targets must be added here in order to appear in the intellij project.
                                   """),

        "symlinks": attr.string_dict(default={}),

        "tools": attr.label_list(default=[], allow_files=True),
    },

    outputs={
        "intellij_files": "intellij_files",
        "install_intellij_files_script": "install_intellij_files_script",
        "fswatch_and_install_intellij_files_mac_sh": "fswatch_and_install_intellij_files_mac.sh",
    },
)
