;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2020 Mathieu Othacehe <m.othacehe@gmail.com>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu system images raspberry-pi)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader u-boot)
  #:use-module (gnu image)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)  
  #:use-module (gnu packages linux)
  #:use-module (gnu packages image)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system image)
  #:use-module (guix build-system copy)
  #:use-module (guix download)
  #:use-module (guix packages)
  #:use-module (guix platforms arm)
  #:use-module (srfi srfi-26)
  #:use-module ((guix licenses) #:prefix license:)

  #:export (raspbery-pi-barebones-os
            raspbery-pi-image-type
            raspbery-pi-barebones-raw-image))

(use-modules (gnu)
             (gnu bootloader u-boot))
(use-package-modules bootloaders screen ssh)
(use-modules (nongnu packages linux))
(use-modules (guix gexp))

(include "rpi-kernel.scm")
(include "reterminal.scm")


(define-public brcm80211-firmware
  (package
    (name "brcm80211-firmware")
    (version "20210818-1")
    (source (origin
              (method url-fetch)
              (uri (string-append 
                    "http://ftp.debian.org/debian/pool/non-free/f/firmware-nonfree/firmware-brcm80211_"
                    version "_all.deb"))
              (sha256 (base32 "04wg9fqay6rpg80b7s4h4g2kwq8msbh81lb3nd0jj45nnxrdxy7p"))))
    (build-system copy-build-system)
    (native-inputs (list tar bzip2))
    (arguments
      '(#:phases
        (modify-phases %standard-phases
          (replace 'unpack
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((source (assoc-ref inputs "source")))
                (invoke "ar" "x" source)
                (invoke "ls")
                (invoke "tar" "-xvf" "data.tar.xz"))))
          (add-after 'install 'make-symlinks
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((out (assoc-ref outputs "out")))
                (symlink (string-append out "/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt")
                         (string-append out "/lib/firmware/brcm/brcmfmac43455-sdio.txt"))
                (symlink (string-append out "/lib/firmware/brcm/brcmfmac43455-sdio.bin")
                         (string-append out "/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-compute-module.bin"))))))
        #:install-plan
        '(("lib/firmware/" "lib/firmware"))))
    (home-page "https://packages.debian.org/sid/firmware-brcm80211")
    (synopsis "Binary firmware for Broadcom/Cypress 802.11 wireless cards")
    (description "This package contains the binary firmware for wireless
network cards supported by the brcmsmac or brcmfmac driver.")
    (license license:expat)))


(define (install-rpi-efi-loader grub-efi esp)
  "Install in ESP directory the given GRUB-EFI bootloader.  Configure it to
load the Grub bootloader located in the 'Guix_image' root partition."
  (let ((uboot-binary "/libexec/u-boot.bin"))
    (copy-file #$(file-append (u-boot-rpi-arm64) uboot-binary ) "/")))

(define u-boot-rpi-arm64
  (make-u-boot-package "rpi_arm64" "aarch64-linux-gnu"))

(define install-rpi-arm64-u-boot
  #~(lambda (bootloader root-index image)
      #t))

(define u-boot-rpi-arm64-bootloader
  (bootloader
   (inherit u-boot-bootloader)
   (package u-boot-rpi-arm64)
   (disk-image-installer install-rpi-arm64-u-boot)))

(define raspberry-pi-barebones-os
  (operating-system
   (host-name "viso")
   (timezone "Europe/Paris")
   (locale "en_US.utf8")
   (bootloader (bootloader-configuration
		(bootloader  u-boot-rpi-arm64-bootloader)
		(targets '("/dev/vda"))
    (device-tree-support? #f)))
   (kernel linux-raspberry-5.15)
   (kernel-arguments (cons* "cgroup_enable=memory"
                            %default-kernel-arguments))
   (initrd-modules '())
   (firmware (list raspberrypi-firmware brcm80211-firmware))
   (file-systems (append (list 
                          (file-system
                           (device (file-system-label "BOOT"))
                           (mount-point "/boot/firmware")
                           (type "vfat"))
                          (file-system
                           (device (file-system-label "RASPIROOT"))
                           (mount-point "/")
                           (type "ext4")))
                         %base-file-systems))
   (services %base-services)
   (packages %base-packages)
   (users (cons (user-account
                 (name "pi")
                 (comment "raspberrypi user")
                 (password (crypt "123" "123$456"))
                 (group "users")
                 (supplementary-groups '("wheel")))
                %base-user-accounts))
   ;;(kernel-loadable-modules %reterminal-kernel-modules)
   ))

(define rpi-boot-partition
  (partition
   (size (* 128 (expt 2 20)))
   (label "BOOT")
   (file-system "fat32")
   (flags '())
   (initializer (gexp (lambda* (root #:key
                                 grub-efi
                                 #:allow-other-keys)
                               (use-modules (guix build utils))
                               (mkdir-p root)
                               (copy-recursively #$(file-append u-boot-rpi-arm64 "/libexec/u-boot.bin" )
						 (string-append root "/u-boot.bin"))
                               (copy-recursively #$(file-append raspberrypi-firmware "/" ) root)
                               (copy-recursively #$(local-file "config.txt")
						 (string-append root "/config.txt"))
                               (copy-recursively #$(local-file "cmdline.txt")
						 (string-append root "/cmdline.txt"))
			       )))))

(define rpi-root-partition
  (partition
   (size 'guess)
   (label "RASPIROOT")
   (file-system "ext4")
   (flags '(boot))
   (initializer (gexp initialize-root-partition))))

(define raspberry-pi-image
  (image
   (format 'disk-image)
   (partitions (list rpi-boot-partition rpi-root-partition))))

(define raspberry-pi-image-type
  (image-type
   (name 'raspberry-pi-raw)
   (constructor (cut image-with-os raspberry-pi-image <>))))

(define raspberry-pi-barebones-raw-image
  (image
   (inherit
    (os+platform->image raspberry-pi-barebones-os aarch64-linux
                        #:type raspberry-pi-image-type))
   (partition-table-type 'mbr)
   (name 'raspberry-pi-barebones-raw-image)))

;; Return the default image.
raspberry-pi-barebones-raw-image
