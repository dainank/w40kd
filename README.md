# w40kd
This repository contains **performance configurations** and **better drop-in binaries** to **increase performance** of the game _Warhammer 40,000: Darktide_. 

A **script can be used to directly install** all of this automatically in one go (see installation instructions directly below).

----

>[!IMPORTANT]
> To **install** follow these instructions:
> 1. `git clone https://github.com/dainank/w40kd.git`
> 2. `cd w40kd`
> 3. `./script/auto-setup.ps1` 

_Example Usage_:
<img width="1089" height="329" alt="Example Usage" src="https://github.com/user-attachments/assets/53afed9a-ec8f-47df-9f4d-62025a677218" />

----

>[!TIP]
> If you are unsure where your `Warhammer 40,000 DARKTIDE` folder is located, you can find it via Steam through the following steps:
> 1. _Right-click_ on your library entry of the game and select **Properties...** <img width="397" height="229" alt="Step 1" src="https://github.com/user-attachments/assets/7a326b2d-fb17-4b9a-affa-f9516a76f5fb" />
> 2. Navigate to the **Installed Files** section. <img width="421" height="385" alt="Step 2" src="https://github.com/user-attachments/assets/05b8699b-a6d7-4cb3-88d5-af9e45156486" />
> 3. Click the **Browse...** button. <img width="421" height="193" alt="image" src="https://github.com/user-attachments/assets/7dc70e5d-61cc-403c-a553-c48b0e6dde99" />
> 
> This will open your File Explorer at the `*\Steam\steamapps\common\Warhammer 40,000 DARKTIDE` location, thus you can find the correct directories from there.

----

## Addional Information

The script handles everything automatically
- The two `*.dll` **binary** files should be placed under `*\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\binaries`
    - If you do not trust the `*.dll`'s here, you can download them directly from __Microsoft__ [here](https://devblogs.microsoft.com/directx/directstorage-api-downloads/). Our script fetches them from there too (see `script/auto-setup.ps1` and the `Get-LatestDirectStorageVersion` function).

- The two `*.ini` **config** files should be placed under `*\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\bundle\application_settings`
