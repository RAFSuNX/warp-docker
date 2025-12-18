# Setting up as WARP connector

> [!CAUTION]
> **This article is out-of-date.** Cloudflare has changed their document. The `mdm.xml` file instruction are no longer exist in the [link](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/warp-connector/#4-install-a-warp-connector) of step 1. You can find it in [Wayback Machine](https://web.archive.org/web/20240128042134/https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/warp-connector/). **However, it may not work as expected due to the changes made by Cloudflare.** Please use at your own risk.
> 
> We are discussing this issue in [#68](https://github.com/cmj2002/warp-docker/issues/68).

If you want to setup [WARP Connector](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/warp-connector)

> [!NOTE]
> If you have already started the container, stop it and delete the data directory.

1. Create `mdm.xml` as explained in Cloudflare WARP Connector [step 4](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/warp-connector/#4-install-a-warp-connector)
2. Mount the `mdm.xml` to path `/var/lib/cloudflare-warp/mdm.xml`
3. Start the container

Sample Docker Compose File:

```yaml
services:
  warp:
    image: ghcr.io/rafsunx/warp-docker:latest
    container_name: warp
    restart: always
    # add removed rule back (https://github.com/opencontainers/runc/pull/3468)
    device_cgroup_rules:
      - 'c 10:200 rwm'
    ports:
      - "1080:1080"
    environment:
      - WARP_SLEEP=2
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    volumes:
      - ./data:/var/lib/cloudflare-warp
      - ./config/warp/mdm.xml:/var/lib/cloudflare-warp/mdm.xml
```
