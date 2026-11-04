# CaptureMac
Clipping on Mac, made easy. Quickly save the last few minutes of your game, app, or window (including game audio) with a single hotkey, or simply click record.

To get started, open terminal and run:

```sh
curl -fsSL https://raw.githubusercontent.com/whoisjonah/CaptureMac/master/install.sh | bash
```

### Uploading to R2

This allows uploading clips directly into your personal [Cloudflare R2](https://developers.cloudflare.com/r2/) bucket and then copying the shareable link. This is ideal if you wish to share/store your videos to people using your own custom domain. There's absolutely no limitations here and Cloudflare R2 is free up to 10GB of storage (a lot).

- Create a new bucket by going to https://dash.cloudflare.com, `Storage & Database`, and `R2 Object Storage`. 
- Go to the settings of your new bucket and either connect a custom domain or enable the r2.dev subdomain. This will be your public URL.
- Once back in the R2 overview select and copy your Account ID.
- Under Manage API tokens create a new token. Select the Object Read & Write permission and apply it to your bucket only. Once created copy down your Access Key ID and Secret Access Key. You'll only ever see the secret once.
- Finally back in CaptureMac head to Settings > Upload and enter your details. Click Test connection and make sure everything is working.

### License

Copyright © 2026 whoisjonah

Licensed under the [GNU General Public License v3.0](LICENSE). You can use, modify and share this project, but if you share a modified version, you must make its source code available under the same license.
