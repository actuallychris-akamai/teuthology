FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
# Undo Docker image tweaks that prevent services from starting via systemd
RUN rm -f /usr/sbin/policy-rc.d && \
    dpkg-divert --local --rename --remove /sbin/initctl || true
RUN ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime && \
    echo "Etc/UTC" > /etc/timezone && \
    apt update && \
    apt -y install \
        sudo \
        openssh-server \
        hostname \
        curl \
        python3-pip \
        python3-venv \
        apache2 \
        nfs-kernel-server \
        gnupg \
        tzdata \
        chrony \
        lvm2 \
        valgrind \
        systemd \
        udev && \
    echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/unstable/xUbuntu_22.04/ /" > /etc/apt/sources.list.d/devel:kubic:libcontainers:unstable.list && \
    curl -fsSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/unstable/xUbuntu_22.04/Release.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/devel_kubic_libcontainers_unstable.gpg && \
    apt update && \
    apt -y install podman crun fuse-overlayfs && \
    apt remove --assume-yes --purge apparmor && \
    apt clean all
# Podman-in-podman: subuid/subgid, storage dirs, and volumes
RUN echo "root:0:65535" > /etc/subuid && \
    echo "root:0:65535" > /etc/subgid && \
    mkdir -p /var/lib/containers/storage \
             /root/.local/share/containers \
             /var/lib/shared/overlay-images \
             /var/lib/shared/overlay-layers \
             /var/lib/shared/vfs-images \
             /var/lib/shared/vfs-layers && \
    touch /var/lib/shared/overlay-images/images.lock \
          /var/lib/shared/overlay-layers/layers.lock \
          /var/lib/shared/vfs-images/images.lock \
          /var/lib/shared/vfs-layers/layers.lock
VOLUME /var/lib/containers
VOLUME /root/.local/share/containers
# Podman-in-podman: container engine config
RUN printf '[containers]\nnetns="host"\nuserns="host"\nipcns="host"\nutsns="host"\ncgroupns="host"\ncgroups="disabled"\nlog_driver = "k8s-file"\n[engine]\ncgroup_manager = "cgroupfs"\nevents_logger="file"\nruntime="crun"\n' > /etc/containers/containers.conf && \
    mkdir -p /root/.config/containers && \
    printf '[containers]\nvolumes = [\n\t"/proc:/proc",\n]\ndefault_sysctls = []\n' > /root/.config/containers/containers.conf
# Podman-in-podman: storage config with fuse-overlayfs
RUN printf '[storage]\ndriver = "overlay"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n[storage.options]\nadditionalimagestores = [\n"/var/lib/shared",\n]\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\nmountopt = "nodev,fsync=0"\n' > /etc/containers/storage.conf
RUN printf 'root soft nofile 65536\nroot hard nofile 65536\nroot soft core unlimited\nroot hard core unlimited\nubuntu soft nofile 65536\nubuntu hard nofile 65536\nubuntu soft core unlimited\nubuntu hard core unlimited\n' > /etc/security/limits.d/99-teuthology.conf
COPY testnode_start.sh /
COPY testnode_stop.sh /
COPY testnode_sudoers /etc/sudoers.d/teuthology
RUN \
    ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N '' && \
    sed -i 's/#PermitRootLogin yes/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    echo 'UseDNS no' >> /etc/ssh/sshd_config && \
    echo 'MaxSessions 100' >> /etc/ssh/sshd_config && \
    ln -s /root /home/root && \
    mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh && \
    useradd -g sudo -s /bin/bash ubuntu && \
    mkdir -p /home/ubuntu/.ssh && \
    chmod 700 /home/ubuntu/.ssh && \
    chown -R ubuntu /home/ubuntu
RUN echo 'DEBIAN_FRONTEND=noninteractive' >> /etc/environment && \
    echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    printf '[Unit]\nDescription=Testnode setup\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/testnode_start.sh\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/testnode-setup.service && \
    printf '[Unit]\nDescription=Ensure required items in /run/ are present\n\n[Service]\nType=oneshot\nRemainAfterExit=true\nExecStartPre=mkdir -p /run/udev\nExecStartPre=mkdir -p /run/sshd\nExecStartPre=touch /run/.containerenv /.dockerenv\nExecStart=true\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/run-fs.service && \
    printf '[Unit]\nDescription=Write /scratch_devs\n\n[Service]\nType=oneshot\nRemainAfterExit=true\nExecStart=/bin/bash -c "ls -1 /dev/loop[0-9]* > /scratch_devs"\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/scratch-devs.service && \
    mkdir -p /var/lib/ceph && chmod 777 /var/lib/ceph && \
    systemctl enable testnode-setup.service && \
    systemctl enable run-fs.service && \
    systemctl enable scratch-devs.service && \
    systemctl disable apache2 && \
    systemctl enable ssh
EXPOSE 22
CMD ["/sbin/init"]
