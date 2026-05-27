(function () {
    const scene = document.querySelector('.scene-capture');
    if (!scene) return;

    const overlay = scene.querySelector('.capture-overlay');
    const selection = scene.querySelector('.capture-selection');
    const badge = scene.querySelector('.capture-badge');
    const dimLabel = badge?.querySelector('.dim');
    const snapHint = badge?.querySelector('.capture-snap-hint');
    if (!overlay || !selection || !badge || !dimLabel || !snapHint) return;

    const MIN_SIZE = 48;
    const SNAP_THRESHOLD = 40;
    const SNAP_FRAME_PADDING = 56;
    const HANDLES = ['nw', 'ne', 'sw', 'se'];
    const RESIZE_EDGES = {
        nw: { left: true, top: true },
        ne: { right: true, top: true },
        sw: { left: true, bottom: true },
        se: { right: true, bottom: true },
    };

    let interaction = null;
    let dimScale = null;
    let lastOverlayPoint = null;
    let shiftHeld = false;

    function setShiftHeld(held) {
        shiftHeld = held;
        selection.classList.toggle('is-snapping', held);
        updateBadge(Boolean(interaction), held);
    }

    function clamp(value, min, max) {
        return Math.min(Math.max(value, min), max);
    }

    function getOverlayBounds() {
        return overlay.getBoundingClientRect();
    }

    function readRect() {
        return {
            x: selection.offsetLeft,
            y: selection.offsetTop,
            width: selection.offsetWidth,
            height: selection.offsetHeight,
        };
    }

    function applyRect(rect) {
        selection.style.left = `${rect.x}px`;
        selection.style.top = `${rect.y}px`;
        selection.style.width = `${rect.width}px`;
        selection.style.height = `${rect.height}px`;
    }

    function anchorPixels() {
        const bounds = getOverlayBounds();
        const rect = selection.getBoundingClientRect();

        selection.style.width = `${rect.width}px`;
        selection.style.height = `${rect.height}px`;
        selection.style.left = `${rect.left - bounds.left}px`;
        selection.style.top = `${rect.top - bounds.top}px`;

        if (!dimScale) {
            dimScale = {
                x: 840 / rect.width,
                y: 620 / rect.height,
            };
        }
    }

    function clampRect(rect, bounds) {
        const width = clamp(rect.width, MIN_SIZE, bounds.width);
        const height = clamp(rect.height, MIN_SIZE, bounds.height);
        const x = clamp(rect.x, 0, bounds.width - width);
        const y = clamp(rect.y, 0, bounds.height - height);
        return { x, y, width, height };
    }

    function getSnapFrames() {
        const bounds = getOverlayBounds();
        const elements = [
            scene.querySelector('.frame-card'),
            scene.querySelector('.mac-window.figma-win'),
        ].filter(Boolean);

        return elements.map((element) => {
            const rect = element.getBoundingClientRect();
            return {
                left: rect.left - bounds.left,
                top: rect.top - bounds.top,
                right: rect.right - bounds.left,
                bottom: rect.bottom - bounds.top,
                width: rect.width,
                height: rect.height,
            };
        });
    }


    function nearestSnap(value, targets) {
        let best = null;
        for (const target of targets) {
            const distance = Math.abs(value - target);
            if (distance > SNAP_THRESHOLD) continue;
            if (best === null || distance < best.distance) {
                best = { distance, target };
            }
        }
        return best?.target ?? null;
    }

    function expandedFrameContainsPoint(frame, x, y) {
        return (
            x >= frame.left - SNAP_FRAME_PADDING &&
            x <= frame.right + SNAP_FRAME_PADDING &&
            y >= frame.top - SNAP_FRAME_PADDING &&
            y <= frame.bottom + SNAP_FRAME_PADDING
        );
    }

    function snapRectEdges(rect, xTargets, yTargets) {
        let { x, y, width, height } = rect;

        const snapLeft = nearestSnap(x, xTargets);
        if (snapLeft !== null) x = snapLeft;

        const snapRight = nearestSnap(x + width, xTargets);
        if (snapRight !== null) x = snapRight - width;

        const snapTop = nearestSnap(y, yTargets);
        if (snapTop !== null) y = snapTop;

        const snapBottom = nearestSnap(y + height, yTargets);
        if (snapBottom !== null) y = snapBottom - height;

        return { x, y, width, height };
    }

    function snapMoveRect(proposedRect, cursorX, cursorY, shiftHeld) {
        if (!shiftHeld) return proposedRect;

        for (const frame of getSnapFrames()) {
            if (!expandedFrameContainsPoint(frame, cursorX, cursorY)) continue;
            return {
                x: frame.left,
                y: frame.top,
                width: frame.width,
                height: frame.height,
            };
        }

        const xTargets = [];
        const yTargets = [];
        for (const frame of getSnapFrames()) {
            xTargets.push(frame.left, frame.right);
            yTargets.push(frame.top, frame.bottom);
        }

        return snapRectEdges(proposedRect, xTargets, yTargets);
    }

    function snapResizeRect(rect, edges, shiftHeld) {
        if (!shiftHeld) return rect;

        const xTargets = [];
        const yTargets = [];
        for (const frame of getSnapFrames()) {
            xTargets.push(frame.left, frame.right);
            yTargets.push(frame.top, frame.bottom);
        }

        let { x, y, width, height } = rect;

        if (edges.left) {
            const snap = nearestSnap(x, xTargets);
            if (snap !== null) {
                const nextWidth = x + width - snap;
                if (nextWidth >= MIN_SIZE) {
                    x = snap;
                    width = nextWidth;
                }
            }
        }

        if (edges.right) {
            const snap = nearestSnap(x + width, xTargets);
            if (snap !== null) {
                const nextWidth = snap - x;
                if (nextWidth >= MIN_SIZE) {
                    width = nextWidth;
                }
            }
        }

        if (edges.top) {
            const snap = nearestSnap(y, yTargets);
            if (snap !== null) {
                const nextHeight = y + height - snap;
                if (nextHeight >= MIN_SIZE) {
                    y = snap;
                    height = nextHeight;
                }
            }
        }

        if (edges.bottom) {
            const snap = nearestSnap(y + height, yTargets);
            if (snap !== null) {
                const nextHeight = snap - y;
                if (nextHeight >= MIN_SIZE) {
                    height = nextHeight;
                }
            }
        }

        return { x, y, width, height };
    }

    function formatDimensions(width, height) {
        if (!dimScale) return '840 × 620';
        const w = Math.round(width * dimScale.x);
        const h = Math.round(height * dimScale.y);
        return `${w} × ${h}`;
    }

    function updateBadge(isDragging, snapping) {
        const rect = readRect();
        dimLabel.textContent = formatDimensions(rect.width, rect.height);

        if (snapping) {
            snapHint.hidden = false;
            snapHint.textContent = 'Snapping';
        } else if (isDragging) {
            snapHint.hidden = false;
            snapHint.textContent = 'Hold Shift to snap';
        } else {
            snapHint.hidden = true;
        }
    }

    function handleFromTarget(target) {
        if (!(target instanceof Element)) return null;
        for (const handle of HANDLES) {
            if (target.classList.contains(handle)) return handle;
        }
        return null;
    }

    function resizeRect(startRect, mode, dx, dy, bounds, shiftHeld) {
        let { x, y, width, height } = startRect;

        if (mode === 'nw') {
            x = startRect.x + dx;
            y = startRect.y + dy;
            width = startRect.width - dx;
            height = startRect.height - dy;
        } else if (mode === 'ne') {
            y = startRect.y + dy;
            width = startRect.width + dx;
            height = startRect.height - dy;
        } else if (mode === 'sw') {
            x = startRect.x + dx;
            width = startRect.width - dx;
            height = startRect.height + dy;
        } else if (mode === 'se') {
            width = startRect.width + dx;
            height = startRect.height + dy;
        }

        if (width < MIN_SIZE) {
            if (mode === 'nw' || mode === 'sw') {
                x = startRect.x + startRect.width - MIN_SIZE;
            }
            width = MIN_SIZE;
        }

        if (height < MIN_SIZE) {
            if (mode === 'nw' || mode === 'ne') {
                y = startRect.y + startRect.height - MIN_SIZE;
            }
            height = MIN_SIZE;
        }

        let rect = clampRect({ x, y, width, height }, bounds);
        rect = snapResizeRect(rect, RESIZE_EDGES[mode], shiftHeld);
        return clampRect(rect, bounds);
    }

    function applyInteraction(overlayPoint, shiftHeld) {
        if (!interaction) return;

        lastOverlayPoint = overlayPoint;

        const dx = overlayPoint.x - interaction.startPointer.x;
        const dy = overlayPoint.y - interaction.startPointer.y;

        if (interaction.mode === 'move') {
            const proposed = {
                x: overlayPoint.x - interaction.moveOffset.x,
                y: overlayPoint.y - interaction.moveOffset.y,
                width: interaction.startRect.width,
                height: interaction.startRect.height,
            };

            applyRect(
                clampRect(
                    snapMoveRect(proposed, overlayPoint.x, overlayPoint.y, shiftHeld),
                    interaction.bounds
                )
            );
        } else {
            applyRect(
                resizeRect(
                    interaction.startRect,
                    interaction.mode,
                    dx,
                    dy,
                    interaction.bounds,
                    shiftHeld
                )
            );
        }

        updateBadge(true, shiftHeld);
    }

    function overlayPointFromEvent(event) {
        const bounds = getOverlayBounds();
        return {
            x: event.clientX - bounds.left,
            y: event.clientY - bounds.top,
        };
    }

    selection.addEventListener('pointerdown', (event) => {
        if (event.button !== 0) return;

        anchorPixels();

        const handle = handleFromTarget(event.target);
        const bounds = getOverlayBounds();
        const startRect = readRect();
        const overlayPoint = overlayPointFromEvent(event);

        interaction = {
            pointerId: event.pointerId,
            mode: handle ?? 'move',
            startPointer: overlayPoint,
            startRect,
            bounds: {
                width: bounds.width,
                height: bounds.height,
            },
            moveOffset: handle
                ? null
                : {
                      x: overlayPoint.x - startRect.x,
                      y: overlayPoint.y - startRect.y,
                  },
        };

        selection.classList.toggle('is-dragging', !handle);
        selection.classList.toggle('is-resizing', Boolean(handle));
        if (event.shiftKey !== shiftHeld) setShiftHeld(event.shiftKey);
        else updateBadge(true, shiftHeld);
        selection.setPointerCapture(event.pointerId);
        event.preventDefault();
    });

    selection.addEventListener('pointermove', (event) => {
        if (!interaction || event.pointerId !== interaction.pointerId) return;
        if (event.shiftKey !== shiftHeld) setShiftHeld(event.shiftKey);
        applyInteraction(overlayPointFromEvent(event), shiftHeld);
    });

    function endInteraction(event) {
        if (!interaction || event.pointerId !== interaction.pointerId) return;

        interaction = null;
        selection.classList.remove('is-dragging', 'is-resizing');
        updateBadge(false, shiftHeld);
        selection.releasePointerCapture(event.pointerId);
    }

    selection.addEventListener('pointerup', endInteraction);
    selection.addEventListener('pointercancel', endInteraction);

    window.addEventListener('keydown', (event) => {
        if (event.key !== 'Shift') return;
        if (!shiftHeld) setShiftHeld(true);
        if (interaction && lastOverlayPoint) applyInteraction(lastOverlayPoint, true);
    });

    window.addEventListener('keyup', (event) => {
        if (event.key !== 'Shift') return;
        if (shiftHeld) setShiftHeld(false);
        if (interaction && lastOverlayPoint) applyInteraction(lastOverlayPoint, false);
    });
})();
