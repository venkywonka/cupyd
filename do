#!/usr/bin/env python
from string import Template
import inspect
import subprocess
import argparse
import shutil
import json
import os
import socket
import getpass
import tempfile
import pkgutil


def runcmd(cmd):
    subprocess.check_call(cmd, shell=True)


def dockercmd(*args):
    cmd = "docker " + " ".join(args)
    runcmd(cmd)


def dockercmdout(*args):
    cmd = "docker " + " ".join(args)
    return subprocess.check_output(cmd, shell=True)


def copydir(src, dst):
    shutil.copytree(src, dst)


def findimage(image, dir="images"):
    for importer, package, _ in pkgutil.iter_modules([dir]):
        fullName = '%s.%s' % (dir, package)
        module = importer.find_module(package).load_module(fullName)
        imgs = module.images()
        for img in imgs.keys():
            if img == image:
                return module, imgs[img]
    raise Exception("Failed to find image '%s'!" % image)


def validateargs(args):
    if args.build and args.pull:
        raise Exception("Cannot pass both '-build' and '-pull'!")
    if args.pull and args.push:
        raise Exception("Useless combination of options '-pull' and '-push'!")
    if args.build and not args.image:
        raise Exception("'-image' is needed with '-build'!")
    if args.copy and not args.build:
        raise Exception("'-copy' is meaningful only with '-build'!")
    if args.image is None:
        raise Exception("'image' is mandatory!")
    args.module, args.imageArgs = findimage(args.image)


def parseargs():
    desc = "Wrapper to work with gpu containers"
    parser = argparse.ArgumentParser(description=desc)
    parser.add_argument("-build", default=False, action="store_true",
        help="Build the docker image locally first")
    parser.add_argument("-dns", default=[], action="append", type=str,
        help="Pass DNS servers to be used inside container")
    parser.add_argument("-ipc", default=None, type=str,
        help="how to use shared memory between processes.")
    parser.add_argument("-nfsmount", action="store_true", default=False,
        help="Mount the nfs-root of current dir as /work. Implies -nopwd")
    parser.add_argument("-nopwd", action="store_true", default=False,
        help="Do not mount current dir as /work")
    parser.add_argument("-copy", default=None, type=str,
        help="Copy the temporary build dir into this dir")
    parser.add_argument("-repo", default=None, type=str,
        help="Remote registry prefix to pull/push this image from/to")
    parser.add_argument("-printComments", action="store_true", default=False,
        help="Print the origin of docker commands in the generated Dockerfile")
    parser.add_argument("-pull", action="store_true", default=False,
        help="Pull the image first from a remote registry.")
    parser.add_argument("-push", action="store_true", default=False,
        help="Push the local image to a remote registry.")
    parser.add_argument("-run", default=False, action="store_true",
        help="Run the image to launch a container")
    parser.add_argument("-runas", choices=["user", "root", "uid"],
        default="root", type=str,
        help="Run as specified. Default is root. Options: "
        " user [run as current user by switching user inside the container]"
        " root [run as root, without any of these switching abilities]"
        " uid  ['-u' option to docker. To run on non-privileged containers]")
    parser.add_argument("-security", type=str, default=None,
        help="Same as --security-opt option of docker")
    parser.add_argument("-v", default=[], action="append", type=str,
        help="Volumes to mount. Same syntax as docker run")
    parser.add_argument("image", help="Image to build/push/pull/launch")
    parser.add_argument("cmd", nargs=argparse.REMAINDER,
        help="Command to run inside the container")
    args = parser.parse_args()
    validateargs(args)
    return args


class Puller:
    def __init__(self, args):
        self.args = args

    def run(self):
        here = self.args.image
        there = self.args.repo + here
        dockercmd("pull", there)
        dockercmd("tag", there, here)
        dockercmd("rmi", there)


class Pusher:
    def __init__(self, args):
        self.args = args

    def run(self):
        here = self.args.image
        there = self.args.repo + here
        dockercmd("tag", here, there)
        dockercmd("push", there)
        dockercmd("rmi", there)


class Runner:
    def __init__(self, args):
        self.args = args

    def run(self):
        args = self.args
        finalcmd = ["-it", "--rm", "--runtime", "nvidia"]
        finalcmd += self.__getPort(args.image)
        finalcmd += self.__getVols(args)
        finalcmd += self.__getNFSmount(args)
        finalcmd += self.__getUser(args)
        finalcmd += self.__getDns(args)
        if args.ipc is not None:
            finalcmd += ["--ipc=%s" % args.ipc]
        if args.security is not None:
            finalcmd += ["--security-opt=\"%s\"" % args.security]
        finalcmd.append(args.image)
        finalcmd += self.__getCmd(args)
        print("Host IP Address: %s" % socket.gethostbyname(socket.getfqdn()))
        print(finalcmd)
        dockercmd("run", *finalcmd)

    def __get(self, image, *args):
        output = dockercmdout("inspect", image)
        output = json.loads(output)[0]
        for a in args:
            if a not in output:
                return ""
            output = output[a]
        return output

    def __getCmd(self, args):
        arr = self.__get(args.image, "Config", "Cmd")
        if len(args.cmd) > 0:
            cmd = " ".join(args.cmd)
        elif len(arr) > 0:
            cmd = " ".join(arr)
        else:
            cmd = "/bin/bash"
        # single quotes around to directly pass this command to container!
        return ["'%s'" % cmd]

    def __getPort(self, image):
        arr = self.__get(image, "Config", "ExposedPorts")
        if len(arr) <= 0:
            return ""
        out = []
        for p in arr.keys():
            tmp = int(p.replace("/tcp", ""))
            # system ports?
            tmp1 = tmp + 8192 if tmp < 2048 else tmp
            out.append("-p %d:%d" % (tmp1, tmp))
        return out

    def __getIP(self, rhost):
        out = socket.getaddrinfo(rhost, 0)
        return out[0][4][0]

    def __getNFSinfo(self):
        out = subprocess.check_output("df . | tail -n1 | awk '{print $1}'",
                                      shell=True)
        out = out.rstrip()
        (rhost, vol) = out.split(":")
        ip = self.__getIP(rhost)
        basevol = os.path.basename(vol)
        return (ip, vol, basevol)

    def __getNFSmount(self, args):
        cmd = []
        if not args.nfsmount:
            return cmd
        (ip, vol, basevol) = self.__getNFSinfo()
        volopts = [
            "o=addr=%s" % ip,
            "device=:%s" % vol,
            "type=nfs,source=%s,target=/work" % basevol
        ]
        mountopt = "type=volume"
        for vo in volopts:
            mountopt += ",volume-opt=%s" % vo
        cmd.append("--mount")
        cmd.append(mountopt)
        return cmd

    def __getVols(self, args):
        vols = []
        for vol in args.v:
            vols.append("-v %s" % vol)
        # Prohibit pwd-mounting if nfsmount is set!
        if not args.nopwd and not args.nfsmount:
            vols.append("-v %s:/work:rw" % os.getcwd())
            vols.append("-w /work")
        return vols

    def __getDns(self, args):
        dns = []
        for d in args.dns:
            dns.append("--dns %s" % d)
        return dns

    def __getUser(self, args):
        out = []
        bindir = os.path.abspath(os.path.dirname(__file__))
        if args.runas == "user":
            out.append("-e RUNAS_UID=%d" % os.getuid())
            out.append("-e RUNAS_USER=%s" % getpass.getuser())
        elif args.runas == "uid":
            uid = os.getuid()
            gid = os.getgid()
            out.append("-u %d:%d" % (uid, gid))
            out.append("-e RUNAS_USER=%s" % getpass.getuser())
        return out


class Writer:
    def __init__(self, verbose=False, file="Dockerfile"):
        self.verbose = verbose
        self.file = file
        self.fp = open(self.file, "w")
        self.past = set()
        self.fp.write("# Generated file. Do NOT modify!\n")

    def emit(self, str, caller=1, **kwargs):
        str = str.rstrip() + "\n"
        stack = inspect.stack()
        frameinfo = inspect.getframeinfo(stack[caller][0])
        frame = "%s:%d" % (frameinfo.filename, frameinfo.lineno)
        if frame in self.past:
            if self.verbose:
                self.fp.write("### %s already called\n" % frame)
            return
        self.past.add(frame)
        if self.verbose:
            start = "### Start: from %s ###\n" % frame
            end = "### End: from %s ###\n" % frame
            str = start + str + end
        s = Template(str)
        self.fp.write(s.substitute(kwargs))

    def packages(self, pkgs, caller=2, **kwargs):
        if len(pkgs) <= 0:
            return
        if "installOpts" not in kwargs:
            kwargs["installOpts"] = ""
        str = """RUN apt-get update && \\
    apt-get install -y --no-install-recommends $installOpts && """
        for p in pkgs:
            str += "\\\n        %s " % p
        str += """&& \\
    rm -rf /var/lib/apt/lists/*"""
        self.emit(str, caller=caller, **kwargs)

    def condaPackages(self, pkgs, channels=[], caller=2, **kwargs):
        if len(pkgs) <= 0:
            return
        if "installOpts" not in kwargs:
            kwargs["installOpts"] = ""
        ch = "-c " + " -c ".join(channels) + " " if len(channels) > 0 else ""
        str = "RUN conda install $installOpts " + ch
        for p in pkgs:
            str += "\\\n        %s " % p
        str += """&& \\
    conda clean -ya"""
        self.emit(str, caller=caller, **kwargs)


class Builder:
    def __init__(self, args):
        self.args = args
        self.builddir = tempfile.mkdtemp()
        self.pwd = os.getcwd()
        os.chdir(self.builddir)
        print("Working out of %s..." % self.builddir)
        self.writer = Writer(verbose=self.args.printComments)

    def __del__(self):
        del self.writer
        os.chdir(self.pwd)
        if self.args.copy:
            print("Copying %s to %s..." % (self.builddir, self.args.copy))
            shutil.copytree(self.builddir, self.args.copy)
        print("Cleaning up %s..." % self.builddir)
        shutil.rmtree(self.builddir)

    def run(self):
        imgArgs = self.args.imageArgs
        print("Generating Dockerfile...")
        self.writer.emit("FROM %s\n" % imgArgs["base"])
        self.args.module.emit(writer=self.writer, **imgArgs)
        print("Building image '%s'..." % self.args.image)
        if "needsContext" in imgArgs and imgArgs["needsContext"]:
            print("Copying contexts...")
            copydir(os.path.join(self.pwd, "shared-contexts"),
                    os.path.join(self.builddir, "contexts"))
        dockercmd("build", "-t", self.args.image, ".")


if __name__ == "__main__":
    args = parseargs()
    if args.build:
        Builder(args).run()
    elif args.pull:
        Puller(args).run()
    # push should only be done after a build!
    if args.push:
        Pusher(args).run()
    if args.run:
        Runner(args).run()
