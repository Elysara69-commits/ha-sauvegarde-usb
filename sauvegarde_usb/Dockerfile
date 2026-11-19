ARG BUILD_FROM
FROM ${BUILD_FROM}

# util-linux : mount/umount/blkid complets ; exfatprogs/e2fsprogs/ntfs-3g-progs : vérifications de systèmes de fichiers
RUN apk add --no-cache \
      util-linux \
      coreutils \
      findutils \
      curl \
      jq \
      exfatprogs \
      e2fsprogs \
      dosfstools

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
