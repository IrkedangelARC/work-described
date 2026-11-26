#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""ARC Design Studio CLI — arc-studio command."""

from __future__ import annotations

import logging
import sys
from pathlib import Path

import click

from arc_studio import __version__, config

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)-8s %(message)s",
)


@click.group()
@click.version_option(__version__, prog_name="arc-studio")
def cli():
    """ARC Design Studio — AI-powered media authoring for live event graphics."""
    pass


# ── ingest ──────────────────────────────────────────────────────────────────

@cli.command()
@click.argument("paths", nargs=-1, type=click.Path(exists=True))
@click.option("--collection", "-c", default="default", help="Collection name")
@click.option("--tag", "-t", multiple=True, help="Tags to apply")
@click.option("--recursive/--no-recursive", default=True, help="Scan subdirectories")
def ingest(paths: tuple[str, ...], collection: str, tag: tuple[str, ...], recursive: bool):
    """Ingest media files or directories into the asset registry.

    Supports: PNG, JPG, TIFF, HEIC, WebP, PSD, SVG, EPS, AI, RAW (CR2/ARW/NEF/DNG),
    MP4, MOV, ProRes, MXF, AVI, MKV, PDF, PPTX, DOCX, Keynote, WAV, MP3, AIFF,
    TTF, OTF — and more.
    """
    from arc_studio.assets.registry import AssetRegistry

    if not paths:
        click.echo("No paths specified. Pass files or directories to ingest.")
        sys.exit(1)

    registry = AssetRegistry()
    tags_list = list(tag)
    total = 0

    for p in paths:
        path = Path(p).resolve()
        if path.is_dir():
            result = registry.scan(path, collection, recursive, tags_list)
            total += len(result.assets)
        else:
            registry.add_file(path, collection, tags=tags_list)
            total += 1

    registry.save_manifest()

    summary = registry.summary()
    click.echo(f"\nIngested {total} assets into collection '{collection}'")
    for media_type, count in summary["by_type"].items():
        click.echo(f"  {media_type:12s}  {count}")
    click.echo(f"\nRegistry saved to {registry._manifest_path}")


# ── assets ──────────────────────────────────────────────────────────────────

@cli.command()
@click.option("--collection", "-c", default=None, help="Filter by collection")
@click.option("--type", "-t", "media_type", default=None, help="Filter by type")
def assets(collection: str | None, media_type: str | None):
    """List registered assets."""
    from arc_studio.assets.registry import AssetRegistry
    from arc_studio.models.media import MediaType

    registry = AssetRegistry()
    registry.load_manifest()

    if not registry.collections:
        click.echo("No assets registered. Run 'arc-studio ingest' first.")
        return

    for name, coll in registry.collections.items():
        if collection and name != collection:
            continue

        click.echo(f"\n[{name}] — {len(coll.assets)} assets")
        for asset in coll.assets:
            if media_type and asset.media_type.value != media_type:
                continue
            dims = f"{asset.width}x{asset.height}" if asset.dimensions else "—"
            dur = f"{asset.duration_seconds:.1f}s" if asset.duration_seconds else ""
            pages = f"{asset.page_count}pg" if asset.page_count else ""
            size = f"{asset.file_size_bytes / 1024:.0f}KB"
            extra = " ".join(filter(None, [dims, dur, pages, size]))
            click.echo(f"  {asset.media_type.value:10s}  {asset.filename:40s}  {extra}")


# ── generate ────────────────────────────────────────────────────────────────

@cli.command()
@click.argument("arc_number")
@click.option("--brand", "-b", default="arc", help="Brand profile slug")
@click.option("--output", "-o", type=click.Path(), default=None, help="Output directory")
@click.option("--ai-backgrounds", is_flag=True, help="Generate AI backgrounds (Phase 3)")
def generate(arc_number: str, brand: str, output: str | None, ai_backgrounds: bool):
    """Generate a complete graphics package for an event.

    ARC_NUMBER: Event identifier (e.g., JOB-0000 or 0000)
    """
    from arc_studio.events import read_event
    from arc_studio.models.brand import BrandProfile
    from arc_studio.models.graphic import GraphicSpec, ShowManifest
    from arc_studio.export.package import EventPackage

    # Load event
    event = read_event(arc_number)
    if not event:
        click.echo(f"Event {arc_number} not found in registry.")
        click.echo(f"Registry path: {config.EVENT_REGISTRY_PATH}")
        sys.exit(1)

    click.echo(f"\nEvent: {event.event_title}")
    click.echo(f"  ARC#: {event.arc_number}")
    click.echo(f"  Date: {event.display_date}")
    click.echo(f"  Client: {event.client_name}")
    click.echo(f"  Venue: {event.venue}")
    click.echo(f"  Speakers: {len(event.speaker_names)}")

    # Load brand
    brand_path = config.BRANDS_DIR / f"{brand}.json"
    if brand_path.exists():
        brand_profile = BrandProfile.load(brand_path)
    else:
        brand_profile = BrandProfile.arc_default()
        click.echo(f"  Brand: {brand_profile.name} (default)")

    # Build graphics
    graphics = []

    # 1. Title card
    graphics.append(GraphicSpec(
        line1=event.event_title,
        line2=event.organization or event.client_name,
        line3=event.display_date,
        animation="fadeUp",
        accentColor=brand_profile.colors.primary,
        template="fullWidth",
        graphicType="fullTitle",
    ))

    # 2. Speaker lower thirds
    for speaker in event.speakers:
        graphics.append(GraphicSpec(
            line1=speaker.name,
            line2=speaker.title,
            line3=speaker.organization,
            animation="slideFromLeft",
            accentColor=brand_profile.colors.primary,
            template="fullWidth",
            graphicType="lowerThird",
        ))

    # 3. Session lower thirds (for speakers within sessions)
    for session in event.sessions:
        for speaker in session.speakers:
            if speaker.name not in [g.line1 for g in graphics]:
                graphics.append(GraphicSpec(
                    line1=speaker.name,
                    line2=speaker.title or session.name,
                    line3=speaker.organization,
                    animation="slideFromLeft",
                    accentColor=brand_profile.colors.primary,
                    template="fullWidth",
                    graphicType="lowerThird",
                ))

    # 4. Session title cards
    for session in event.sessions:
        if session.name:
            time_str = ""
            if session.start_time:
                time_str = session.start_time
                if session.end_time:
                    time_str += f" — {session.end_time}"
            graphics.append(GraphicSpec(
                line1=session.name,
                line2=time_str or None,
                animation="fadeUp",
                accentColor=brand_profile.colors.primary,
                template="fullWidth",
                graphicType="fullTitle",
            ))

    # 5. Venue card
    if event.venue:
        graphics.append(GraphicSpec(
            line1=event.venue,
            line2=event.display_date,
            animation="fadeUp",
            accentColor=brand_profile.colors.primary,
            template="fullWidth",
            graphicType="fullTitle",
            notes="Venue card",
        ))

    # Build manifest
    manifest = ShowManifest(
        name=event.event_title,
        arcNumber=event.arc_number,
        venue=event.venue,
        defaultAnimation="slideFromLeft",
        defaultTemplate="fullWidth",
        graphics=graphics,
    )

    # Package output
    out_dir = Path(output) if output else None
    package = EventPackage(event.arc_number, out_dir)
    manifest_path = package.save_manifest(manifest)
    package.save_metadata({
        "event_title": event.event_title,
        "event_date": event.event_date,
        "brand": brand_profile.name,
        "graphics_count": len(graphics),
        "ai_backgrounds": ai_backgrounds,
    })

    click.echo(f"\nGenerated {len(graphics)} graphics:")
    titles = sum(1 for g in graphics if g.graphicType == "fullTitle")
    lowers = sum(1 for g in graphics if g.graphicType == "lowerThird")
    click.echo(f"  Title cards:   {titles}")
    click.echo(f"  Lower thirds:  {lowers}")
    click.echo(f"\nManifest: {manifest_path}")
    click.echo(f"Package:  {package.root}")
    click.echo("\nImport manifest.json into arc-lower-thirds to use.")


# ── brand ───────────────────────────────────────────────────────────────────

@cli.group()
def brand():
    """Manage brand profiles."""
    pass


@brand.command("list")
def brand_list():
    """List available brand profiles."""
    config.BRANDS_DIR.mkdir(parents=True, exist_ok=True)
    profiles = list(config.BRANDS_DIR.glob("*.json"))
    if not profiles:
        click.echo("No brand profiles found.")
        click.echo(f"Run 'arc-studio brand init' to create the ARC default.")
        return
    for p in profiles:
        click.echo(f"  {p.stem}")


@brand.command("init")
def brand_init():
    """Create the default ARC brand profile."""
    from arc_studio.models.brand import BrandProfile

    config.BRANDS_DIR.mkdir(parents=True, exist_ok=True)
    profile = BrandProfile.arc_default()
    path = config.BRANDS_DIR / "arc.json"
    profile.save(path)
    click.echo(f"Created: {path}")


# ── fusion ──────────────────────────────────────────────────────────────────

@cli.group()
def fusion():
    """DaVinci Resolve Fusion template authoring + post-render derivation."""
    pass


@fusion.command("brand")
@click.option("--slug", "-s", default="arc", help="Brand slug to inspect")
def fusion_brand(slug: str):
    """Show brand tokens resolved for Fusion (hex → float + logo path)."""
    from arc_studio.fusion.brand_loader import FusionBrand
    click.echo(FusionBrand.load(slug).summary())


@fusion.command("install-templates")
@click.option("--dry-run", is_flag=True, help="Show what would happen, don't touch fs")
def fusion_install_templates(dry_run: bool):
    """Symlink arc-design/fusion/templates/ into the Resolve Fusion Templates path.

    After running this, Fusion Title macros saved under fusion/templates/Titles/ARC/
    will appear in Resolve's Edit page → Effects Library → Titles → ARC.
    """
    resolve_support = Path.home() / "Library/Application Support/Blackmagic Design/DaVinci Resolve"
    if not resolve_support.exists():
        click.echo(f"DaVinci Resolve support folder not found: {resolve_support}", err=True)
        click.echo("Open Resolve at least once to initialize it, then re-run.", err=True)
        sys.exit(1)

    target = resolve_support / "Fusion" / "Templates" / "Edit" / "Titles" / "ARC"
    source = (config.STUDIO_ROOT / "fusion" / "templates" / "Titles" / "ARC").resolve()

    if not source.exists():
        click.echo(f"Source template dir missing: {source}", err=True)
        sys.exit(1)

    click.echo(f"Source:  {source}")
    click.echo(f"Target:  {target}")

    if target.exists() or target.is_symlink():
        if target.is_symlink() and target.resolve() == source:
            click.echo("Already linked — nothing to do.")
            return
        click.echo(f"Target exists and is NOT the expected symlink.", err=True)
        click.echo("Remove it manually if you want to replace it.", err=True)
        sys.exit(1)

    if dry_run:
        click.echo("[dry-run] would create symlink")
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    target.symlink_to(source, target_is_directory=True)
    click.echo(f"Linked. Restart Resolve to pick up new templates.")


@fusion.command("derive")
@click.argument("master", type=click.Path(exists=True, dir_okay=False))
@click.option("--template-id", "-t", default="unknown", help="Template identifier for manifest")
@click.option("--brand", "-b", default="arc", help="Brand slug")
@click.option("--skip", multiple=True, type=click.Choice(["lt", "atem", "keyer"]),
              help="Variants to skip (repeatable)")
def fusion_derive(master: str, template_id: str, brand: str, skip: tuple[str, ...]):
    """Derive LT / ATEM / Keyer variants from a master ProRes 4444 render."""
    from arc_studio.fusion.derive import derive_all
    from arc_studio.fusion.manifest import write_manifest

    master_path = Path(master).resolve()
    result = derive_all(master_path, skip=set(skip))

    manifest_path = write_manifest(result, template_id=template_id, brand_slug=brand)
    result.manifest_path = manifest_path

    click.echo(f"\nDerived variants from: {master_path.name}")
    if result.lower_thirds:
        click.echo(f"  LT skin:    {result.lower_thirds.relative_to(config.STUDIO_ROOT)}")
    if result.atem_sequence_dir:
        click.echo(f"  ATEM seq:   {result.atem_sequence_dir.relative_to(config.STUDIO_ROOT)}  ({result.atem_frame_count} frames)")
    if result.keyer_luma:
        click.echo(f"  Keyer luma: {result.keyer_luma.relative_to(config.STUDIO_ROOT)}")
    click.echo(f"\nManifest: {manifest_path.relative_to(config.STUDIO_ROOT)}")


# ── formats ─────────────────────────────────────────────────────────────────

@cli.command()
def formats():
    """List all supported media formats for ingestion."""
    sections = [
        ("Images", config.IMAGE_EXTENSIONS),
        ("Video", config.VIDEO_EXTENSIONS),
        ("Documents", config.DOCUMENT_EXTENSIONS),
        ("Vector", config.VECTOR_EXTENSIONS),
        ("Raw Photos", config.RAW_PHOTO_EXTENSIONS),
        ("Audio", config.AUDIO_EXTENSIONS),
        ("Fonts", config.FONT_EXTENSIONS),
    ]
    click.echo("\nSupported media formats:\n")
    for name, exts in sections:
        sorted_exts = sorted(exts)
        click.echo(f"  {name:12s}  {', '.join(sorted_exts)}")
    click.echo(f"\n  Total: {len(config.ALL_SUPPORTED)} formats")


if __name__ == "__main__":
    cli()
