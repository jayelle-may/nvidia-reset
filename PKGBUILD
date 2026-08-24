# Maintainer: Jayelle May <jayelle.m.may@gmail.com>
pkgname=nvidia-reset
pkgver=1.2.1
pkgrel=1
pkgdesc="Reset NVIDIA graphics drivers without rebooting, similar to Windows' Win+Shift+B driver recovery"
arch=('any')
license=('MIT')
depends=('systemd' 'polkit' 'psmisc' 'kmod')
backup=('etc/nvidia-reset.conf')
source=('nvidia-reset.sh' 'nvidia-reset.service' 'nvidia-reset' '99-nvidia-reset.rules' 'nvidia-reset.conf')
sha256sums=('SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP')

package() {
    install -Dm755 "$srcdir/nvidia-reset.sh" "$pkgdir/usr/lib/nvidia-reset/nvidia-reset.sh"
    install -Dm755 "$srcdir/nvidia-reset" "$pkgdir/usr/bin/nvidia-reset"
    install -Dm644 "$srcdir/nvidia-reset.service" "$pkgdir/usr/lib/systemd/system/nvidia-reset.service"
    install -Dm644 "$srcdir/99-nvidia-reset.rules" "$pkgdir/usr/share/polkit-1/rules.d/99-nvidia-reset.rules"
    install -Dm644 "$srcdir/nvidia-reset.conf" "$pkgdir/etc/nvidia-reset.conf"
}
