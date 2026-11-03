"""Настоящий маленький Whisper: изоляция LoRA и сохранение результата."""
import unittest
import tempfile
import torch
from transformers import WhisperConfig,WhisperForConditionalGeneration

class WhisperLoraTests(unittest.TestCase):
    def model(self):
        torch.manual_seed(7)
        config=WhisperConfig(vocab_size=32,num_mel_bins=4,d_model=8,encoder_layers=1,decoder_layers=1,encoder_attention_heads=2,decoder_attention_heads=2,encoder_ffn_dim=16,decoder_ffn_dim=16,max_source_positions=8,max_target_positions=16,pad_token_id=0,bos_token_id=1,eos_token_id=2,decoder_start_token_id=1,suppress_tokens=[],begin_suppress_tokens=[])
        return WhisperForConditionalGeneration(config)
    def test_обновляет_только_LoRA_декодера_и_слияние_сохраняет_logits(self):
        from Tools.SpeechEvaluation.whisper_lora import add_decoder_lora
        base=self.model();before={n:p.detach().clone() for n,p in base.named_parameters()}
        model=add_decoder_lora(base,rank=2)
        trainable=[n for n,p in model.named_parameters() if p.requires_grad]
        self.assertTrue(trainable)
        self.assertTrue(all('decoder' in n and 'lora_' in n for n in trainable))
        features=torch.randn(1,4,16);labels=torch.tensor([[4,5,2]])
        optimizer=torch.optim.AdamW([p for p in model.parameters() if p.requires_grad],lr=.01)
        for _ in range(2):
            model(input_features=features,labels=labels).loss.backward();optimizer.step();optimizer.zero_grad()
        # Физические базовые тензоры не обновляются даже после оптимизации.
        for n,p in base.named_parameters():
            if 'lora_' not in n:
                original=n.replace('.base_layer','')
                self.assertTrue(torch.equal(before[original],p.detach()),n)
        model.eval()
        with torch.no_grad():expected=model(input_features=features,labels=labels).logits
        with tempfile.TemporaryDirectory() as directory:
            from peft import PeftModel
            model.save_pretrained(directory,safe_serialization=True)
            reloaded=PeftModel.from_pretrained(self.model(),directory,local_files_only=True)
            reloaded.eval()
            with torch.no_grad():restored=reloaded(input_features=features,labels=labels).logits
            torch.testing.assert_close(restored,expected,atol=1e-5,rtol=1e-5)
        merged=model.merge_and_unload();merged.eval()
        with torch.no_grad():actual=merged(input_features=features,labels=labels).logits
        torch.testing.assert_close(actual,expected,atol=1e-5,rtol=1e-5)
    def test_не_принимает_пустой_или_нецелый_rank(self):
        from Tools.SpeechEvaluation.whisper_lora import add_decoder_lora
        for rank in [0,-1,True,1.5]:
            with self.subTest(rank=rank),self.assertRaises(ValueError):add_decoder_lora(self.model(),rank=rank)
