我现在已经# Ubuntu 24.04 环境准备指南

本文档适用于 `Ubuntu 24.04` 本地开发和联调 `ROS Flutter GUI App`。

推荐组合：

- `ROS 2 Jazzy`
- `Flutter 3.27.4`
- `Gazebo Harmonic`
- `RViz2`

## 1. 安装 Flutter 3.27.4

### 1.1 安装系统依赖

```bash
sudo apt update
sudo apt install -y curl git unzip xz-utils zip libglu1-mesa clang cmake ninja-build pkg-config libgtk-3-dev
```

### 1.2 下载并安装 Flutter SDK

```bash
mkdir -p ~/develop
cd ~/develop
curl -LO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.27.4-stable.tar.xz
tar -xf flutter_linux_3.27.4-stable.tar.xz
rm flutter_linux_3.27.4-stable.tar.xz
```

如果你在中国网络环境，可先切换镜像再下载：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
curl -LO https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_3.27.4-stable.tar.xz
```

### 1.3 配置环境变量

```bash
echo 'export PATH="$HOME/develop/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### 1.4 验证 Flutter

```bash
flutter config --enable-linux-desktop
flutter --version
flutter doctor -v
```

## 2. 安装 ROS 2 Jazzy

参考官方文档：<https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html>

```bash
sudo apt update
sudo apt install -y software-properties-common curl
sudo add-apt-repository universe

export ROS_APT_SOURCE_VERSION=$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F "tag_name" | awk -F\" '{print $4}')
curl -L -o /tmp/ros2-apt-source.deb "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.$(. /etc/os-release && echo ${UBUNTU_CODENAME:-${VERSION_CODENAME}})_all.deb"
sudo dpkg -i /tmp/ros2-apt-source.deb

sudo apt update
sudo apt install -y ros-jazzy-desktop
echo "source /opt/ros/jazzy/setup.bash" >> ~/.bashrc
source ~/.bashrc
```

## 3. 安装本项目联调需要的 ROS 包

```bash
sudo apt update
sudo apt install -y ros-jazzy-rosbridge-suite
sudo apt install -y ros-jazzy-web-video-server
sudo apt install -y ros-jazzy-rviz2
sudo apt install -y ros-jazzy-ros-gz
```

说明：

- `rosbridge_suite` 是本项目连接 ROS 的必需组件
- `web_video_server` 用于相机画面显示
- `rviz2` 方便查看地图、激光、TF 等信息
- `ros-gz` 是 ROS 与 Gazebo 的集成层

## 4. 安装 Gazebo Harmonic

仅安装 `ros-jazzy-ros-gz` 不一定会提供 `gz` 命令；如需直接使用 `gz sim`，还需要安装 Gazebo 本体。

参考官方文档：<https://gazebosim.org/docs/harmonic/install_ubuntu/>

```bash
sudo apt update
sudo apt install -y curl lsb-release gnupg

sudo curl https://packages.osrfoundation.org/gazebo.gpg \
  --output /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] https://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" | \
sudo tee /etc/apt/sources.list.d/gazebo-stable.list > /dev/null

sudo apt update
sudo apt install -y gz-harmonic
```

验证：

```bash
gz sim --versions
rviz2
```

## 5. 拉起项目

### 5.1 安装项目依赖

```bash
cd ~/ROS_Flutter_Gui_App
flutter pub get
```

### 5.2 运行 Linux 桌面版

```bash
cd ~/ROS_Flutter_Gui_App
flutter run -d linux
```

如果出现 GTK 缺失：

```bash
sudo apt install -y libgtk-3-dev pkg-config ninja-build cmake clang
```

如果出现安装到 `/usr/local` 的权限错误，请清理 CMake 缓存：

```bash
cd ~/ROS_Flutter_Gui_App
flutter clean
rm -rf build/linux
unset CMAKE_INSTALL_PREFIX
unset DESTDIR
flutter run -d linux
```

## 6. 启动 ROS 服务给 App 使用

### 6.1 启动 rosbridge

```bash
source /opt/ros/jazzy/setup.bash
ros2 launch rosbridge_server rosbridge_websocket_launch.xml
```

### 6.2 启动 web_video_server

```bash
source /opt/ros/jazzy/setup.bash
ros2 run web_video_server web_video_server
```

App 默认连接参数可填写：

- Host: `127.0.0.1`
- Port: `9090`

## 7. 官方 Demo 联调建议

### 7.1 最推荐：Nav2 仿真 Demo

适合测试：

- 地图显示
- 机器人位姿
- 导航目标
- 路径规划

```bash
source /opt/ros/jazzy/setup.bash
sudo apt install -y ros-jazzy-navigation2 ros-jazzy-nav2-bringup
ros2 launch nav2_bringup tb3_simulation_launch.py headless:=False
```

再开一个终端启动 rosbridge：

```bash
source /opt/ros/jazzy/setup.bash
ros2 launch rosbridge_server rosbridge_websocket_launch.xml
```

### 7.2 Gazebo 相机 Demo

```bash
source /opt/ros/jazzy/setup.bash
ros2 launch ros_gz_sim_demos camera.launch.py
```

### 7.3 Gazebo 差速驱动 Demo

```bash
source /opt/ros/jazzy/setup.bash
ros2 launch ros_gz_sim_demos diff_drive.launch.py
```

## 8. 常见问题

### 8.1 `flutter pub get` 提示 Dart 版本不兼容

如果报错类似：

```text
Because ros_flutter_gui_app depends on cbor >=6.3.6 which requires SDK version >=3.7.0 <4.0.0
```

说明当前锁定的 Dart 版本与 `cbor` 新版本不兼容，可将以下依赖固定到 `6.3.5`：

- `pubspec.yaml`
- `thirdparty/roslibdart/pubspec.yaml`

### 8.2 `gz: 未找到命令`

这通常表示只安装了 `ros-jazzy-ros-gz`，但没有安装 Gazebo 本体；请按本文第 4 节安装 `gz-harmonic`。

### 8.3 `rviz2` 在 Wayland 下打不开

可尝试：

```bash
QT_QPA_PLATFORM=xcb rviz2
```
