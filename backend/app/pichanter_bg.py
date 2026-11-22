'''Pichanter - modul hapus background (U-Net + MobileNetV3).

Salinan persis dari notebook (sel 38). Setelah training selesai, file ini boleh
ditimpa dengan pichanter_bgremoval/pichanter_bg.py hasil notebook.
'''
import io
import numpy as np
from PIL import Image, ImageFilter, ImageOps


def _get_interpreter():
    try:                                    # server ringan: pip install ai-edge-litert
        from ai_edge_litert.interpreter import Interpreter
    except ImportError:                     # fallback: TensorFlow penuh
        import tensorflow as tf
        Interpreter = tf.lite.Interpreter
    return Interpreter


class BackgroundRemover:
    def __init__(self, model_path=None, num_threads=4, predict_fn=None, input_size=256):
        '''model_path: file .tflite (server). predict_fn: fungsi X[1,S,S,3] -> mask[1,S,S,1] (mis. model Keras).'''
        if predict_fn is not None:
            self._predict, self.size = predict_fn, input_size
        else:
            self.itp = _get_interpreter()(model_path=str(model_path), num_threads=num_threads)
            self.itp.allocate_tensors()
            self.inp = self.itp.get_input_details()[0]
            self.out = self.itp.get_output_details()[0]
            self.size = int(self.inp["shape"][1])
            self._predict = self._predict_tflite

    def _predict_tflite(self, x):
        self.itp.set_tensor(self.inp["index"], x)
        self.itp.invoke()
        return self.itp.get_tensor(self.out["index"])

    def predict_mask(self, img):
        '''Return (foto RGB, peta probabilitas orang float32 0..1 seukuran foto asli).'''
        rgb = ImageOps.exif_transpose(img).convert("RGB")
        x = np.asarray(rgb.resize((self.size, self.size), Image.BILINEAR), dtype=np.float32)[None]
        m = np.asarray(self._predict(x))[0, ..., 0]
        m = Image.fromarray((np.clip(m, 0, 1) * 255).astype(np.uint8)).resize(rgb.size, Image.BILINEAR)
        return rgb, np.asarray(m, dtype=np.float32) / 255.0

    def remove_background(self, img, feather=1.5, hard_threshold=None):
        '''Return gambar RGBA (background transparan).'''
        rgb, alpha = self.predict_mask(img)
        if hard_threshold is not None:
            alpha = (alpha >= hard_threshold).astype(np.float32)
        a = Image.fromarray((alpha * 255).astype(np.uint8))
        if feather > 0:
            a = a.filter(ImageFilter.GaussianBlur(feather))
        out = rgb.copy()
        out.putalpha(a)
        return out

    def replace_background(self, img, background=(255, 255, 255), feather=1.5):
        '''Ganti background dengan warna (tuple RGB) atau gambar PIL lain.'''
        cut = self.remove_background(img, feather=feather)
        if isinstance(background, Image.Image):
            bg = ImageOps.fit(background.convert("RGB"), cut.size)
        else:
            bg = Image.new("RGB", cut.size, tuple(background))
        bg.paste(cut, mask=cut.getchannel("A"))
        return bg

    @staticmethod
    def to_png_bytes(img):
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return buf.getvalue()
