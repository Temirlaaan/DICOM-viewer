# User Guide

Guide for physicians and technicians using the DICOM Web Viewer.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Finding Studies](#finding-studies)
3. [Viewing Images](#viewing-images)
4. [Measurement Tools](#measurement-tools)
5. [3D and MPR Views](#3d-and-mpr-views)
6. [Account Management](#account-management)
7. [Getting Help](#getting-help)

---

## Getting Started

### Accessing the Viewer

1. Open your web browser (Chrome, Firefox, or Edge recommended)
2. Navigate to: `https://imaging.your-domain.com`
3. You will be redirected to the login page

<!-- TODO: add screenshot of login page -->

### Logging In

1. Enter your username and password
2. Click "Sign In"
3. On first login, you will be asked to change your password

<!-- TODO: add screenshot of login form -->

### First-Time Password Change

1. Enter your current (temporary) password
2. Enter your new password (minimum 12 characters)
3. Confirm your new password
4. Click "Submit"

---

## Finding Studies

### Study List

After logging in, you will see the study list showing all studies from your clinic(s).

<!-- TODO: add screenshot of study list -->

### Search Options

| Field | Description | Example |
|-------|-------------|---------|
| Patient Name | Search by patient name | "Smith" or "Smith^John" |
| Patient ID | Search by patient ID | "12345" |
| Accession | Search by accession number | "ACC001" |
| Study Date | Filter by date range | Select from calendar |
| Modality | Filter by type | CT, MR, DX, etc. |

### Quick Search

1. Type in the search box at the top
2. Press Enter or click Search
3. Results update automatically

### Date Filters

- **Today**: Studies from today
- **Last 7 Days**: Recent studies
- **Last 30 Days**: Monthly view
- **Custom Range**: Select specific dates

---

## Viewing Images

### Opening a Study

1. Find the study in the list
2. Double-click or click the study row
3. The viewer will load with all series

<!-- TODO: add screenshot of viewer -->

### Viewer Layout

| Area | Description |
|------|-------------|
| **Left Panel** | Series thumbnails |
| **Center** | Main viewing area |
| **Top Toolbar** | Tools and actions |
| **Right Panel** | Measurements (if enabled) |

### Basic Navigation

| Action | Mouse | Keyboard |
|--------|-------|----------|
| Scroll slices | Mouse wheel | Up/Down arrows |
| Zoom | Right-click + drag | +/- keys |
| Pan | Middle-click + drag | P key + drag |
| Window/Level | Left-click + drag | W key + drag |

### Window/Level Presets

Common presets for CT images:

| Preset | Window | Level | Use For |
|--------|--------|-------|---------|
| Soft Tissue | 400 | 40 | General viewing |
| Lung | 1500 | -600 | Chest CT |
| Bone | 2000 | 500 | Skeletal |
| Brain | 80 | 40 | Head CT |

To apply a preset: Right-click → Window/Level Presets

---

## Measurement Tools

### Available Tools

| Tool | Icon | Description |
|------|------|-------------|
| Length | Ruler | Measure distance |
| Angle | Angle | Measure angles |
| Ellipse | Oval | Area/density |
| Rectangle | Box | Region stats |
| Freehand | Pencil | Draw region |

### Making a Measurement

1. Select the tool from the toolbar
2. Click on the image to start
3. Drag to end point
4. Release to complete

<!-- TODO: add screenshot of measurement -->

### Viewing Measurements

- Measurements appear on the image
- List shown in right panel
- Click measurement to highlight

### Deleting Measurements

1. Click on the measurement
2. Press Delete key, or
3. Right-click → Delete

---

## 3D and MPR Views

### Multiplanar Reconstruction (MPR)

MPR shows three orthogonal views:
- **Axial**: Top-down view
- **Sagittal**: Side view
- **Coronal**: Front view

To open MPR:
1. Open a study
2. Click "MPR" in the mode selector

<!-- TODO: add screenshot of MPR -->

### Navigating MPR

- Scroll in any view to update others
- Click a point to sync all views
- Drag crosshairs to navigate

### 3D Volume Rendering

(Available for compatible studies)

1. Click "3D" in the mode selector
2. Use presets for different views:
   - Bone
   - Soft tissue
   - Vascular

---

## Account Management

### Changing Your Password

1. Click your username in the top right
2. Select "Account Settings"
3. Click "Password" section
4. Enter current password
5. Enter new password (twice)
6. Click "Save"

### Logging Out

1. Click your username in the top right
2. Click "Sign Out"

**Important**: Always log out when finished, especially on shared computers.

### Session Timeout

- Sessions automatically expire after 8 hours of inactivity
- You will be prompted to log in again
- Unsaved work may be lost

---

## Getting Help

### Common Issues

| Problem | Solution |
|---------|----------|
| Can't find a study | Check date range, verify clinic access |
| Images loading slowly | Check internet connection |
| Tools not responding | Refresh the page |
| Login issues | Contact administrator |

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Space | Reset viewport |
| R | Rotate clockwise |
| L | Rotate counter-clockwise |
| H | Flip horizontal |
| V | Flip vertical |
| I | Invert (negative) |
| C | Cine (auto-scroll) |
| M | Length tool |
| Z | Zoom tool |
| W | Window/Level tool |
| P | Pan tool |

### Contact Support

- **Email**: support@your-domain.com
- **Phone**: +7 XXX XXX XXXX
- **Hours**: Mon-Fri, 9:00-18:00

When reporting issues, please include:
1. Your username
2. Study details (Patient ID, Date)
3. Description of the problem
4. Screenshots if possible

---

## Tips for Best Experience

1. **Use a modern browser** - Chrome or Firefox work best
2. **Good internet connection** - 3D/MPR require more bandwidth
3. **Large monitor** - Better for detailed viewing
4. **Log out when done** - Keep your account secure
5. **Bookmark the site** - Easy access next time

---

## Privacy Reminder

- Patient data is confidential
- Only access studies for clinical purposes
- Don't share your login credentials
- Report any suspicious activity
