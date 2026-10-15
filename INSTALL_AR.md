<p align="center">
  <a href="INSTALL.md">English</a> · <b>العربية</b>
  &nbsp;|&nbsp; <a href="README_AR.md">اقرأني</a>
</p>

<h1 align="center">تثبيت KAGE-MAN.DOJO</h1>

<div dir="rtl">

أمر واحد يبني الميدان كاملًا على جهاز Ubuntu 20.04 واحد في VirtualBox: يُنشئ
Vagrant الشبكات، ويُقلع الجهاز، ويثبّت Docker، ويبني قطاعات macvlan الثلاثة،
ثم يبني ويشغّل كل المعامل الـ 26 إضافة إلى خادم DNS الخاص بقطاع WAN (بسياسة
`restart=unless-stopped` لتبقى بعد إعادة التشغيل).

> تُشغّل المُثبِّت **على مضيفك** (Linux أو macOS أو Windows). هو يُشغّل
> Vagrant/VirtualBox، وكل ما عداه يجري داخل الجهاز الافتراضي. **لا** تُشغّل
> `setup.py` أو `make` على مضيفك — فهذه تعمل داخل الجهاز فقط.

---

## 1. متطلبات المضيف

| | |
|---|---|
| **VirtualBox** | 6.1 أو 7.x (مُختبَر على 7.2) |
| **Vagrant** | ≥ 2.2.14 |
| **المعالج** | تفعيل VT-x/AMD-V من BIOS/UEFI؛ يُفضَّل 4 أنوية فأكثر |
| **الذاكرة** | 8GB للجهاز افتراضيًا؛ يُفضَّل **12–16GB متاحة** إن شغّلت كل المعامل دفعة واحدة |
| **القرص** | ~40–80GB فارغة (صور المعامل + صندوق الأساس) |
| **الإنترنت** | مطلوب في البناء الأول (تنزيل الصندوق وDocker وصور المعامل) |

الجهاز الافتراضي **8192MB / 4 vCPU**. تشغيل كل الحاويات (~27) دفعة واحدة ثقيل،
فامنحه أكثر (`KAGE_MEMORY`/`KAGE_CPUS`) أو هيّئ دون تشغيل (`KAGE_START=none`).

---

## 2. تثبيت المتطلبات

### Linux

| التوزيعة | الأمر |
|---|---|
| Arch / CachyOS / Manjaro | `sudo pacman -S virtualbox virtualbox-host-dkms vagrant` |
| Debian / Ubuntu | `sudo apt-get install -y virtualbox vagrant` |
| Fedora / RHEL | `sudo dnf install -y VirtualBox vagrant` |
| openSUSE | `sudo zypper install -y virtualbox vagrant` |

بعد تثبيت VirtualBox، حمّل وحدة النواة وأضف نفسك إلى المجموعة (ثم سجّل الخروج
والدخول):

```bash
sudo modprobe vboxdrv
sudo usermod -aG vboxusers "$USER"
```

### Windows

استخدم مدير حِزَم (شغّل الطرفية كمسؤول Administrator):

```powershell
winget install HashiCorp.Vagrant Oracle.VirtualBox
# أو:  choco install -y vagrant virtualbox
```

ثم **أعد فتح** PowerShell ليصبح `vagrant` و`VBoxManage` ضمن `PATH`.

> **تعارض Hyper-V / WSL2:** لا يستطيع VirtualBox تشغيل الأجهزة بينما يملك
> Hyper-V المحاكاة الافتراضية. إن فشل إقلاع الأجهزة، عطّل Hyper-V / منصّة
> المُحاكي (أو نفّذ `bcdedit /set hypervisorlaunchtype off` وأعد التشغيل).
> لاحظ أن Docker Desktop (WSL2) يعيد تفعيل Hyper-V عادةً.

### macOS

```bash
brew install --cask virtualbox vagrant
```

---

## 3. إحضار الشيفرة

```bash
git clone <this-repo-url> KAGE-MAN.DOJO
cd KAGE-MAN.DOJO
```

---

## 4. البناء — بأمر واحد

### Linux / macOS

```bash
./install.sh
```

### Windows (PowerShell)

```powershell
.\install.ps1
# إن كانت البرامج النصية محظورة:
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

يتحقق كلا المُغلِّفَين من متطلبات المضيف ثم يُنفّذان `vagrant up`. ويعمل
`vagrant up` وحده أيضًا — المُغلِّفات تضيف الشعار وفحص المتطلبات والخيارات.

**ما الذي يحدث، بالترتيب:**

1. إنشاء ثلاث شبكات NAT في VirtualBox — `KAGE-DOJO-DMZ/INT/WAN`
2. إقلاع جهاز Ubuntu 20.04 باسم **`KAGE-MAN.DOJO`**
3. تثبيت Docker + ملف seccomp + docker-compose + make
4. إسناد العنوان `.250` للمضيف على كل قطاع وبناء شبكات macvlan
5. توليد ملف compose لكل معمل
6. بناء **وتشغيل** كل المعامل الـ 26 + خادم DNS لقطاع WAN

البناء الأول يستغرق وقتًا (تنزيل + بناء صور). ما يليه من `vagrant up` سريع.

---

## 5. الخيارات

الأعلام (bash `--flag` / PowerShell `-Flag`):

| العلم | الأثر |
|---|---|
| `--no-start` / `-NoStart` | التهيئة والبناء دون تشغيل المعامل |
| `--gui` / `-Gui` | فتح نافذة VirtualBox (تُظهر شعار الإقلاع) |
| `--provision` / `-Provision` | إعادة التهيئة على جهاز قائم |
| `--destroy` / `-Destroy` | حذف الجهاز |

متغيرات البيئة (تُمرَّر مباشرة إلى `vagrant up`):

| المتغير | الافتراضي | المعنى |
|---|---|---|
| `KAGE_MEMORY` | `8192` | ذاكرة الجهاز (MB) |
| `KAGE_CPUS` | `4` | عدد الأنوية |
| `KAGE_START` | `up` | `up` = بناء+تشغيل الكل · `build` = بناء فقط · `none` = تهيئة فقط |
| `KAGE_GUI` | *(معطّل)* | `1` يفتح نافذة الطرفية |
| `KAGE_BOX` | `ubuntu/focal64` | صندوق الأساس |
| `KAGE_DISK` | `80GB` | قرص الجذر (يحتاج `vagrant plugin install vagrant-disksize`) |

```bash
KAGE_MEMORY=12288 KAGE_CPUS=6 ./install.sh      # جهاز أكبر
KAGE_START=none ./install.sh                     # تهيئة فقط، وشغّل المعامل يدويًا
```

```powershell
$env:KAGE_MEMORY=12288; .\install.ps1
```

---

## 6. استخدام الميدان

```bash
vagrant ssh                       # الدخول إلى الجهاز
cd /opt/kage-man                  # الميدان يقيم هنا داخل الجهاز
sudo docker ps                    # ما الذي يعمل
make ps | make health | make smoke
make up LAB=activemq              # تشغيل معمل واحد  (make down LAB=... للإيقاف)
make up                           # تشغيل الكل  (ثقيل)
```

**بيانات الدخول:** الطرفية `vagrant` / `vagrant` (مع `sudo` بلا كلمة مرور)؛
و`vagrant ssh` يستخدم المفتاح المُولَّد ولا يحتاج كلمة مرور.

### جهاز المهاجم (Kali)

اربط جهاز Kali بشبكة **`KAGE-DOJO-WAN`**، وأعطه عنوانًا ثابتًا `10.0.8.x`،
واستخدم خادم DNS الخاص بالميدان:

```bash
echo 'nameserver 10.0.8.53' | sudo tee /etc/resolv.conf
curl http://www.shopizer-online.com/          # ← struts2 @ 10.0.8.21
```

امشِ في الحملة من WAN إلى الداخل (WAN هي نقطة الدخول الوحيدة).

---

## 7. إدارة الجهاز

```bash
vagrant halt                      # إيقاف الجهاز (الحاويات تعود عند الإقلاع التالي)
vagrant up                        # تشغيله ثانية
vagrant provision                 # إعادة التثبيت/البناء كاملًا
./install.sh --destroy            # حذف الجهاز  (أو: vagrant destroy KAGE-MAN.DOJO -f)
```

لإزالة شبكات VirtualBox أيضًا: `./scripts/vbox-networks.sh remove`
(Linux/macOS) أو `scripts\vbox-networks.ps1 remove` (Windows).

---

## 8. حلّ المشكلات

**`env: 'apt-get': No such file or directory` عند تشغيل `setup.py`.**
شغّلت `setup.py` على مضيفك. هو يعمل داخل جهاز Ubuntu فقط — استخدم `vagrant ssh`
ثم `cd /opt/kage-man && sudo python3 setup.py`. على المضيف نفّذ `./install.sh`
(أو `vagrant up`).

**`vagrant up` يتوقف برسالة `undefined method 'exists?' for class File`.**
إضافة `vagrant-vbguest` قديمة مع Ruby 3.2+. يعطّل ملف Vagrantfile إعادة البناء
التلقائي لها، فإن حدث ذلك حدّثها: `vagrant plugin update vagrant-vbguest` ثم
`vagrant reload`.

**`vagrant destroy KAGE-MAN.DOJO` يقول "not found" / "not created".**
`KAGE-MAN.DOJO` هو اسم الجهاز في VirtualBox وفي Vagrant معًا. استخدم
`vagrant destroy -f` أو `./install.sh --destroy`. وإن أُنشئ الجهاز قبل هذه
التسمية فاحذفه مباشرة: `VBoxManage unregistervm KAGE-MAN.DOJO --delete` ثم
`rm -rf .vagrant`.

**حاوية تُعيد التشغيل باستمرار.** حاويات التهيئة ذات التشغيل الواحد تُولَّد
بسياسة `restart: "no"`؛ أما الخدمات طويلة العمل فبـ `unless-stopped`. إن عدّلت
ملف compose فأعد التوليد بـ `make gen` وأعد إنشاء المعمل (`make up LAB=<name>`).

**`curl` من مضيف Docker لا يصل إلى عنوان معمل.** هذا متوقَّع: مع macvlan لا
يستطيع المضيف التحدث إلى حاوياته. اختبر من داخل القطاع (`make smoke` /
`make health`) أو من جهاز Kali على ذلك القطاع.

**الشعار لا يظهر عند الإقلاع.** يعمل الجهاز بلا واجهة افتراضيًا. شغّله بـ
`--gui` (`KAGE_GUI=1`) لفتح النافذة؛ الشعار يظهر هناك فقط.

**أجهزة VirtualBox لا تُقلع على ويندوز.** راجع ملاحظة Hyper-V/WSL2 في القسم 2.

**ذاكرة غير كافية / فشل تشغيل المعامل.** ارفع `KAGE_MEMORY`، أو هيّئ بـ
`KAGE_START=none` وشغّل المعامل درسًا درسًا عبر `make up LAB=<name>`.

</div>
