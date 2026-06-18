from __future__ import annotations

import timm
import torch
from torch import nn


class ISICMultimodalModel(nn.Module):
    def __init__(
        self,
        backbone_name: str,
        metadata_dim: int,
        metadata_hidden_dim: int,
        metadata_embedding_dim: int,
        projection_dim: int,
        dropout: float,
        pretrained: bool,
        use_image: bool = True,
        use_metadata: bool = True,
    ) -> None:
        super().__init__()
        if not use_image and not use_metadata:
            raise ValueError("At least one of use_image/use_metadata must be enabled")
        self.use_image = use_image
        self.use_metadata = use_metadata
        self.backbone = timm.create_model(
            backbone_name, pretrained=pretrained, num_classes=0, global_pool="avg"
        )
        image_dim = self.backbone.num_features
        self.metadata_encoder = nn.Sequential(
            nn.Linear(metadata_dim, metadata_hidden_dim),
            nn.LayerNorm(metadata_hidden_dim),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(metadata_hidden_dim, metadata_embedding_dim),
            nn.LayerNorm(metadata_embedding_dim),
            nn.GELU(),
        )
        self.projection_head = nn.Sequential(
            nn.Linear(image_dim, image_dim), nn.GELU(), nn.Linear(image_dim, projection_dim)
        )
        self.image_classifier = nn.Linear(image_dim, 8)
        fused_dim = (image_dim if use_image else 0) + (metadata_embedding_dim if use_metadata else 0)
        self.fusion = nn.Sequential(
            nn.LayerNorm(fused_dim), nn.Dropout(dropout), nn.Linear(fused_dim, 512), nn.GELU()
        )
        self.diagnosis_head = nn.Linear(512, 8)
        self.melanoma_head = nn.Linear(512, 1)
        self.malignant_head = nn.Linear(512, 1)

    def encode_images(self, images: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        embedding = self.backbone(images)
        projection = self.projection_head(embedding)
        return embedding, projection

    def classify(
        self, image_embedding: torch.Tensor, metadata: torch.Tensor
    ) -> dict[str, torch.Tensor]:
        features = []
        if self.use_image:
            features.append(image_embedding)
        if self.use_metadata:
            features.append(self.metadata_encoder(metadata))
        fused = self.fusion(torch.cat(features, dim=1) if len(features) > 1 else features[0])
        return {
            "diagnosis": self.diagnosis_head(fused),
            "melanoma": self.melanoma_head(fused).squeeze(1),
            "malignant": self.malignant_head(fused).squeeze(1),
        }

    def forward(
        self,
        images: torch.Tensor,
        metadata: torch.Tensor,
        second_images: torch.Tensor | None = None,
    ) -> dict[str, torch.Tensor]:
        if not self.use_image:
            embedding = torch.zeros(
                images.shape[0], self.backbone.num_features, device=images.device, dtype=images.dtype
            )
            projection = self.projection_head(embedding)
            output = self.classify(embedding, metadata)
            output["image_diagnosis"] = self.image_classifier(embedding)
            output["projection"] = projection
            return output

        if second_images is None:
            embedding, projection = self.encode_images(images)
            output = self.classify(embedding, metadata)
            output["image_diagnosis"] = self.image_classifier(embedding)
            output["projection"] = projection
            return output

        batch_size = images.shape[0]
        embeddings, projections = self.encode_images(torch.cat((images, second_images), dim=0))
        image_embedding = (embeddings[:batch_size] + embeddings[batch_size:]) * 0.5
        output = self.classify(image_embedding, metadata)
        output["image_diagnosis"] = self.image_classifier(image_embedding)
        output["projections"] = torch.stack(
            (projections[:batch_size], projections[batch_size:]), dim=1
        )
        return output
