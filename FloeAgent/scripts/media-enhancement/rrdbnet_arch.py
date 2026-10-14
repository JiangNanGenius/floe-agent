# Vendored RRDBNet architecture for the Floe media-enhancement conversion.
#
# Source: XPixelGroup/BasicSR, file basicsr/archs/rrdbnet_arch.py
#   tag:    v1.4.2
#   commit: 651835a1b9d38dbbdaf45750f56906be2364f01a  (immutable pin)
#   url:    https://raw.githubusercontent.com/XPixelGroup/BasicSR/651835a1b9d38dbbdaf45750f56906be2364f01a/basicsr/archs/rrdbnet_arch.py
#   sha256: 6aa8eb3f77e918b90eeff4ebfaf8745abe0c40eb8fcc03abbc1928693d70ab58
#   (byte-identical to the file actually downloaded during the conversion run;
#   verified by verify_rrdbnet_source.py --converted-copy.)
#   Note: the repository path `LICENSE` is a directory, not a file; the actual
#   license text is `LICENSE.txt` (sha256
#   5447872f21ddc29dc0dc060d5c885513c01c904e9da9931bba69898a6fb4d415), copied
#   here as rrdbnet_arch.LICENSE.txt.
# License: Apache-2.0. Copyright 2018-2022 BasicSR Authors.
#
# Minimal local patch (documented, no math changes; verified node-for-node by
# verify_rrdbnet_source.py and bit-exact against the upstream module):
#   1. dropped the `basicsr.utils.registry` import and the
#      `@ARCH_REGISTRY.register()` decorator;
#   2. inlined `make_layer` and `pixel_unshuffle` from
#      basicsr/archs/arch_util.py at the same commit (helper sha256
#      45b322b874057c4bff382cc8f1b64554857b9aa4e0c47e73fe67e4afc0b28ac1);
#   3. dropped the `default_init_weights(...)` call from
#      `ResidualDenseBlock.__init__` and kept a no-op compatible shim, because
#      the conversion always loads the pinned upstream checkpoint and never
#      relies on random initialization;
#   4. docstring/quote-style normalization only.
# `ResidualDenseBlock`, `RRDB` and `RRDBNet.forward` are logic-identical to
# upstream (see media/REPRODUCIBILITY-REVIEW.md).

import torch
from torch import nn as nn
from torch.nn import functional as F


def make_layer(basic_block, num_basic_block, **kwarg):
    """Make layers by stacking the same blocks (basicsr/archs/arch_util.py, v1.4.2)."""
    layers = []
    for _ in range(num_basic_block):
        layers.append(basic_block(**kwarg))
    return nn.Sequential(*layers)


def pixel_unshuffle(x, scale):
    """Pixel unshuffle (basicsr/archs/arch_util.py, v1.4.2)."""
    b, c, hh, hw = x.size()
    out_channel = c * (scale ** 2)
    assert hh % scale == 0 and hw % scale == 0
    h = hh // scale
    w = hw // scale
    x_view = x.view(b, c, h, scale, w, scale)
    return x_view.permute(0, 1, 3, 5, 2, 4).reshape(b, out_channel, h, w)


def default_init_weights(module_list, scale=1, bias_fill=0, **kwargs):  # noqa: ARG001
    """No-op: the conversion always loads the pinned upstream checkpoint."""
    return None


class ResidualDenseBlock(nn.Module):
    """Residual Dense Block (upstream v1.4.2)."""

    def __init__(self, num_feat=64, num_grow_ch=32):
        super(ResidualDenseBlock, self).__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    """Residual in Residual Dense Block (upstream v1.4.2)."""

    def __init__(self, num_feat, num_grow_ch=32):
        super(RRDB, self).__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x


class RRDBNet(nn.Module):
    """RRDBNet as used by Real-ESRGAN x2plus/x4plus (upstream v1.4.2)."""

    def __init__(self, num_in_ch, num_out_ch, scale=4, num_feat=64, num_block=23, num_grow_ch=32):
        super(RRDBNet, self).__init__()
        self.scale = scale
        if scale == 2:
            num_in_ch = num_in_ch * 4
        elif scale == 1:
            num_in_ch = num_in_ch * 16
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = make_layer(RRDB, num_block, num_feat=num_feat, num_grow_ch=num_grow_ch)
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        if self.scale == 2:
            feat = pixel_unshuffle(x, scale=2)
        elif self.scale == 1:
            feat = pixel_unshuffle(x, scale=4)
        else:
            feat = x
        feat = self.conv_first(feat)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out
